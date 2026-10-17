//! Native client-tree composition, independent of shell placement/effects.
//!
//! Plans retain Wayland's client-local geometry. Desktop movement, overview
//! transforms and workspace animations do not invalidate the client image.
//! Popup trees remain independent scene siblings. GPU storage, input revisions
//! and fence ownership are supplied by the external-texture renderer.

use std::collections::{BTreeSet, HashMap};
use std::sync::Arc;

use crate::wire::SurfaceLayerDescription;

const NATIVE_WINDOW_TEXTURE_NAMESPACE: u64 = 1 << 62;
const MAX_NATIVE_WINDOW_PLANS: usize = 32;
const MAX_NATIVE_WINDOW_LAYERS: usize = 32;
const MAX_NATIVE_WINDOW_DIMENSION: u32 = 8192;
const MAX_NATIVE_WINDOW_PIXELS: u64 = 32 * 1024 * 1024;

#[derive(Clone, Copy, Debug, PartialEq)]
pub(super) struct ClientRect {
    pub(super) x: f64,
    pub(super) y: f64,
    pub(super) width: f64,
    pub(super) height: f64,
}

impl ClientRect {
    pub(super) fn new(x: f64, y: f64, width: f64, height: f64) -> Option<Self> {
        let rect = Self {
            x,
            y,
            width,
            height,
        };
        (x.is_finite()
            && y.is_finite()
            && width.is_finite()
            && height.is_finite()
            && width > 0.0
            && height > 0.0
            && (x + width).is_finite()
            && (y + height).is_finite())
        .then_some(rect)
    }

    fn right(self) -> f64 {
        self.x + self.width
    }
    fn bottom(self) -> f64 {
        self.y + self.height
    }

    fn intersection(self, other: Self) -> Option<Self> {
        let x = self.x.max(other.x);
        let y = self.y.max(other.y);
        Self::new(
            x,
            y,
            self.right().min(other.right()) - x,
            self.bottom().min(other.bottom()) - y,
        )
    }

    fn contains(self, other: Self) -> bool {
        self.x <= other.x
            && self.y <= other.y
            && self.right() >= other.right()
            && self.bottom() >= other.bottom()
    }
}

#[derive(Clone, Debug, PartialEq)]
pub(super) struct NativeWindowLayer {
    pub(super) texture_id: i64,
    pub(super) destination: ClientRect,
    pub(super) source: ClientRect,
    pub(super) transform: u32,
    pub(super) opacity: f32,
    pub(super) opaque: bool,
}

#[derive(Clone, Copy, Debug, PartialEq)]
pub(super) struct ClientVertex {
    pub(super) position: [f32; 2],
    pub(super) uv: [f32; 2],
}

impl NativeWindowLayer {
    /// Inverse of RotatedBox followed by the optional horizontal reflection,
    /// matching the existing Wayland buffer-transform contract. Crops remain
    /// in buffer coordinates even when the destination axes are swapped.
    pub(super) fn uv_at(&self, point: [f64; 2], buffer_size: [u32; 2]) -> Option<[f32; 2]> {
        if buffer_size.contains(&0) {
            return None;
        }
        let mut u = (point[0] - self.destination.x) / self.destination.width;
        let v = (point[1] - self.destination.y) / self.destination.height;
        if self.transform & 4 != 0 {
            u = 1.0 - u;
        }
        let [u, v] = match self.transform & 3 {
            0 => [u, v],
            1 => [v, 1.0 - u],
            2 => [1.0 - u, 1.0 - v],
            _ => [1.0 - v, u],
        };
        Some([
            ((self.source.x + u * self.source.width) / f64::from(buffer_size[0])) as f32,
            ((self.source.y + v * self.source.height) / f64::from(buffer_size[1])) as f32,
        ])
    }

    /// Strict crop texel limits used by the native sampler, including crops
    /// narrower than one texel. The input may be an older accepted mailbox
    /// buffer during resize; never sample beyond its actual backing.
    pub(super) fn sample_limits(&self, buffer_size: [u32; 2]) -> Option<[f32; 4]> {
        let source = self.source.intersection(ClientRect::new(
            0.0,
            0.0,
            f64::from(buffer_size[0]),
            f64::from(buffer_size[1]),
        )?)?;
        let half_x = (source.width * 0.5).min(0.5);
        let half_y = (source.height * 0.5).min(0.5);
        Some([
            ((source.x + half_x) / f64::from(buffer_size[0])) as f32,
            ((source.y + half_y) / f64::from(buffer_size[1])) as f32,
            ((source.right() - half_x) / f64::from(buffer_size[0])) as f32,
            ((source.bottom() - half_y) / f64::from(buffer_size[1])) as f32,
        ])
    }
}

#[derive(Clone, Debug, PartialEq)]
pub(super) struct NativeWindowPlan {
    pub(super) window_id: u64,
    pub(super) texture_id: i64,
    pub(super) canvas: ClientRect,
    pub(super) scale: f64,
    pub(super) width: u32,
    pub(super) height: u32,
    pub(super) layers: Vec<NativeWindowLayer>,
}

impl NativeWindowPlan {
    pub(super) fn new(
        window_id: u64,
        canvas: ClientRect,
        scale: f64,
        surfaces: &[SurfaceLayerDescription],
    ) -> Option<Self> {
        if window_id == 0
            || window_id >= NATIVE_WINDOW_TEXTURE_NAMESPACE
            || !scale.is_finite()
            || !(1.0..=8.0).contains(&scale)
            || ClientRect::new(canvas.x, canvas.y, canvas.width, canvas.height).is_none()
        {
            return None;
        }
        let width = (canvas.width * scale).ceil();
        let height = (canvas.height * scale).ceil();
        if width < 1.0
            || height < 1.0
            || width > f64::from(MAX_NATIVE_WINDOW_DIMENSION)
            || height > f64::from(MAX_NATIVE_WINDOW_DIMENSION)
        {
            return None;
        }
        let width = width as u32;
        let height = height as u32;
        if u64::from(width) * u64::from(height) > MAX_NATIVE_WINDOW_PIXELS {
            return None;
        }
        let mut layers = Vec::new();
        let mut opaque_covers = Vec::<ClientRect>::new();
        for surface in surfaces.iter().rev() {
            if surface.popup_root_surface_id != 0
                || surface.texture_id == 0
                || surface.opacity == 0.0
            {
                continue;
            }
            // Synthetic sources must not depend on other synthetic sources.
            if surface.texture_id >= NATIVE_WINDOW_TEXTURE_NAMESPACE
                || surface.transform > 7
                || !surface.opacity.is_finite()
                || !(0.0..=1.0).contains(&surface.opacity)
                || surface.width == 0
                || surface.height == 0
            {
                return None;
            }
            let destination = ClientRect::new(
                surface.surface_x,
                surface.surface_y,
                surface.surface_width,
                surface.surface_height,
            )?;
            let Some(visible) = destination.intersection(canvas) else {
                continue;
            };
            if opaque_covers.iter().any(|cover| cover.contains(visible)) {
                continue;
            }
            let source = ClientRect::new(
                surface.texture_source_x,
                surface.texture_source_y,
                surface.texture_source_width,
                surface.texture_source_height,
            )?;
            if source.x < 0.0
                || source.y < 0.0
                || source.right() > f64::from(surface.width)
                || source.bottom() > f64::from(surface.height)
            {
                return None;
            }
            if surface.opaque && surface.opacity == 1.0 {
                opaque_covers.push(visible);
            }
            layers.push(NativeWindowLayer {
                texture_id: i64::try_from(surface.texture_id).ok()?,
                destination,
                source,
                transform: surface.transform,
                opacity: surface.opacity,
                opaque: surface.opaque,
            });
            if layers.len() > MAX_NATIVE_WINDOW_LAYERS {
                return None;
            }
        }
        // Preserve the existing zero-copy route for a single contributing image.
        if layers.len() < 2 {
            return None;
        }
        layers.reverse();
        Some(Self {
            window_id,
            texture_id: (NATIVE_WINDOW_TEXTURE_NAMESPACE | window_id) as i64,
            canvas,
            scale,
            width,
            height,
            layers,
        })
    }

    pub(super) fn vertices(
        &self,
        layer: &NativeWindowLayer,
        buffer_size: [u32; 2],
    ) -> Option<[ClientVertex; 4]> {
        let visible = layer.destination.intersection(self.canvas)?;
        let points = [
            [visible.x, visible.y],
            [visible.right(), visible.y],
            [visible.x, visible.bottom()],
            [visible.right(), visible.bottom()],
        ];
        let mut vertices = [ClientVertex {
            position: [0.0; 2],
            uv: [0.0; 2],
        }; 4];
        for (vertex, point) in vertices.iter_mut().zip(points) {
            vertex.position = [
                ((point[0] - self.canvas.x) * self.scale) as f32,
                ((point[1] - self.canvas.y) * self.scale) as f32,
            ];
            vertex.uv = layer.uv_at(point, buffer_size)?;
        }
        Some(vertices)
    }
}

#[derive(Debug)]
pub(super) struct VersionedWindowPlan {
    pub(super) revision: u64,
    pub(super) plan: NativeWindowPlan,
}

/// Geometry revision is separate from input buffer revisions. Replacing a
/// child buffer invalidates the merged image without rebuilding its geometry.
#[derive(Default)]
pub(super) struct NativeWindowRegistry {
    plans: HashMap<i64, Arc<VersionedWindowPlan>>,
    dependents: HashMap<i64, BTreeSet<i64>>,
    next_revision: u64,
}

impl NativeWindowRegistry {
    pub(super) fn upsert(&mut self, plan: NativeWindowPlan) -> Option<Arc<VersionedWindowPlan>> {
        if let Some(previous) = self.plans.get(&plan.texture_id)
            && previous.plan == plan
        {
            return Some(Arc::clone(previous));
        }
        if !self.plans.contains_key(&plan.texture_id) && self.plans.len() >= MAX_NATIVE_WINDOW_PLANS
        {
            return None;
        }
        let revision = self.next_revision.checked_add(1)?;
        self.next_revision = revision;
        self.remove(plan.texture_id);
        for layer in &plan.layers {
            self.dependents
                .entry(layer.texture_id)
                .or_default()
                .insert(plan.texture_id);
        }
        let versioned = Arc::new(VersionedWindowPlan { revision, plan });
        self.plans
            .insert(versioned.plan.texture_id, Arc::clone(&versioned));
        Some(versioned)
    }

    /// System images also use high IDs (allocated down from i64::MAX).
    /// Namespace magnitude alone does not establish a native client image.
    pub(super) fn handles_texture(&self, texture_id: i64) -> bool {
        self.plans.contains_key(&texture_id)
    }

    pub(super) fn get(&self, texture_id: i64) -> Option<Arc<VersionedWindowPlan>> {
        self.plans.get(&texture_id).map(Arc::clone)
    }

    pub(super) fn remove(&mut self, texture_id: i64) {
        if let Some(previous) = self.plans.remove(&texture_id) {
            for layer in &previous.plan.layers {
                if let Some(dependents) = self.dependents.get_mut(&layer.texture_id) {
                    dependents.remove(&texture_id);
                    if dependents.is_empty() {
                        self.dependents.remove(&layer.texture_id);
                    }
                }
            }
        }
    }

    pub(super) fn include_dependents(&self, changed: &mut Vec<i64>) {
        let mut additional = BTreeSet::new();
        for input in changed.iter() {
            if let Some(dependents) = self.dependents.get(input) {
                additional.extend(dependents.iter().copied());
            }
        }
        for texture_id in additional {
            if !changed.contains(&texture_id) {
                changed.push(texture_id);
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::wire::SurfaceRoleDescription;

    fn surface(id: u64, rect: ClientRect, buffer: [u32; 2]) -> SurfaceLayerDescription {
        SurfaceLayerDescription {
            surface_id: id,
            parent_surface_id: if id == 1 { 0 } else { 1 },
            popup_root_surface_id: 0,
            role: if id == 1 {
                SurfaceRoleDescription::Root
            } else {
                SurfaceRoleDescription::Subsurface
            },
            texture_id: id,
            width: buffer[0],
            height: buffer[1],
            surface_x: rect.x,
            surface_y: rect.y,
            surface_width: rect.width,
            surface_height: rect.height,
            texture_source_x: 0.0,
            texture_source_y: 0.0,
            texture_source_width: f64::from(buffer[0]),
            texture_source_height: f64::from(buffer[1]),
            transform: 0,
            scale_120: 240,
            composition_order: id as u32,
            opacity: 1.0,
            opaque: false,
            window_geometry: None,
        }
    }

    fn firefox_plan() -> NativeWindowPlan {
        let canvas = ClientRect::new(26.0, 23.0, 1678.0, 1130.0).unwrap();
        NativeWindowPlan::new(
            1,
            canvas,
            2.0,
            &[
                surface(
                    1,
                    ClientRect::new(0.0, 0.0, 1730.0, 1182.0).unwrap(),
                    [3460, 2364],
                ),
                surface(2, canvas, [3356, 2260]),
            ],
        )
        .unwrap()
    }

    fn close(actual: f32, expected: f64) {
        assert!(
            (f64::from(actual) - expected).abs() < 0.00001,
            "{actual} != {expected}"
        );
    }

    #[test]
    fn firefox_layers_merge_in_client_space_without_shadow_padding() {
        let plan = firefox_plan();
        assert_eq!((plan.width, plan.height), (3356, 2260));
        assert_eq!(
            plan.layers
                .iter()
                .map(|layer| layer.texture_id)
                .collect::<Vec<_>>(),
            [1, 2]
        );
        let root = plan.vertices(&plan.layers[0], [3460, 2364]).unwrap();
        assert_eq!(root[0].position, [0.0, 0.0]);
        assert_eq!(root[3].position, [3356.0, 2260.0]);
        close(root[0].uv[0], 52.0 / 3460.0);
        close(root[0].uv[1], 46.0 / 2364.0);
        let child = plan.vertices(&plan.layers[1], [3356, 2260]).unwrap();
        assert_eq!(child[0].uv, [0.0, 0.0]);
        assert_eq!(child[3].uv, [1.0, 1.0]);
    }

    #[test]
    fn all_buffer_orientations_preserve_cropped_corner_order() {
        let mut layer = firefox_plan().layers[1].clone();
        layer.destination = ClientRect::new(4.0, 7.0, 60.0, 40.0).unwrap();
        layer.source = ClientRect::new(8.0, 12.0, 40.0, 20.0).unwrap();
        let corner_order = [
            [0, 1, 2, 3],
            [2, 0, 3, 1],
            [3, 2, 1, 0],
            [1, 3, 0, 2],
            [1, 0, 3, 2],
            [0, 2, 1, 3],
            [2, 3, 0, 1],
            [3, 1, 2, 0],
        ];
        let source = [[8.0, 12.0], [48.0, 12.0], [8.0, 32.0], [48.0, 32.0]];
        let points = [[4.0, 7.0], [64.0, 7.0], [4.0, 47.0], [64.0, 47.0]];
        for (transform, expected) in corner_order.iter().enumerate() {
            layer.transform = transform as u32;
            for (point, corner) in points.iter().zip(expected) {
                let actual = layer.uv_at(*point, [100, 80]).unwrap();
                close(actual[0], source[*corner][0] / 100.0);
                close(actual[1], source[*corner][1] / 80.0);
            }
        }
    }

    #[test]
    fn strict_sampler_limits_handle_subtexel_crop_and_older_resize_buffer() {
        let mut layer = firefox_plan().layers[1].clone();
        layer.source = ClientRect::new(8.0, 12.0, 0.25, 0.75).unwrap();
        let limits = layer.sample_limits([100, 80]).unwrap();
        assert_eq!(limits[0], limits[2]);
        assert_eq!(limits[1], limits[3]);
        layer.source = ClientRect::new(20.0, 10.0, 80.0, 70.0).unwrap();
        let limits = layer.sample_limits([60, 40]).unwrap();
        close(limits[2], 59.5 / 60.0);
        close(limits[3], 39.5 / 40.0);
        assert!(layer.sample_limits([0, 40]).is_none());
    }

    #[test]
    fn popups_single_images_and_fully_covered_roots_keep_existing_routes() {
        let plan = firefox_plan();
        let mut surfaces = vec![
            surface(1, plan.canvas, [3356, 2260]),
            surface(2, plan.canvas, [3356, 2260]),
        ];
        surfaces[1].popup_root_surface_id = 2;
        assert!(NativeWindowPlan::new(1, plan.canvas, 2.0, &surfaces).is_none());
        surfaces[1].popup_root_surface_id = 0;
        surfaces[1].opaque = true;
        assert!(NativeWindowPlan::new(1, plan.canvas, 2.0, &surfaces).is_none());
        surfaces[1].opacity = 0.5;
        assert_eq!(
            NativeWindowPlan::new(1, plan.canvas, 2.0, &surfaces)
                .unwrap()
                .layers
                .len(),
            2
        );
    }

    #[test]
    fn allocation_and_input_limits_reject_invalid_client_geometry() {
        let plan = firefox_plan();
        let layers = [
            surface(1, plan.canvas, [3356, 2260]),
            surface(2, plan.canvas, [3356, 2260]),
        ];
        assert!(
            NativeWindowPlan::new(NATIVE_WINDOW_TEXTURE_NAMESPACE, plan.canvas, 2.0, &layers)
                .is_none()
        );
        assert!(NativeWindowPlan::new(1, plan.canvas, f64::NAN, &layers).is_none());
        assert!(
            NativeWindowPlan::new(
                1,
                ClientRect::new(0.0, 0.0, 9000.0, 9000.0).unwrap(),
                1.0,
                &layers
            )
            .is_none()
        );
        let mut invalid = layers.clone();
        invalid[1].transform = 8;
        assert!(NativeWindowPlan::new(1, plan.canvas, 2.0, &invalid).is_none());
        invalid[1].transform = 0;
        invalid[1].texture_source_width = 4000.0;
        assert!(NativeWindowPlan::new(1, plan.canvas, 2.0, &invalid).is_none());
    }

    #[test]
    fn fractional_scale_retains_exact_source_extent_inside_rounded_allocation() {
        let mut plan = firefox_plan();
        let layers = [
            surface(1, plan.canvas, [3356, 2260]),
            surface(2, plan.canvas, [3356, 2260]),
        ];
        plan = NativeWindowPlan::new(1, plan.canvas, 1.25, &layers).unwrap();
        assert_eq!((plan.width, plan.height), (2098, 1413));
        let vertices = plan.vertices(&plan.layers[0], [3356, 2260]).unwrap();
        assert_eq!(vertices[3].position, [2097.5, 1412.5]);
    }

    #[test]
    fn registry_reuses_geometry_and_routes_each_input_update_to_one_window() {
        let mut registry = NativeWindowRegistry::default();
        let first = registry.upsert(firefox_plan()).unwrap();
        let again = registry.upsert(firefox_plan()).unwrap();
        assert!(Arc::ptr_eq(&first, &again));
        let mut changed = vec![2, 1, 2];
        registry.include_dependents(&mut changed);
        assert_eq!(
            changed
                .iter()
                .filter(|id| **id == first.plan.texture_id)
                .count(),
            1
        );
        let mut resized = firefox_plan();
        resized.layers[1].source.width -= 1.0;
        let next = registry.upsert(resized).unwrap();
        assert!(next.revision > first.revision);
        assert_eq!(first.plan.layers[1].source.width, 3356.0);
        assert_eq!(
            registry.get(next.plan.texture_id).unwrap().revision,
            next.revision
        );
        registry.remove(next.plan.texture_id);
        let mut changed = vec![1, 2];
        registry.include_dependents(&mut changed);
        assert_eq!(changed, [1, 2]);
    }

    #[test]
    fn native_routing_preserves_reserved_system_images() {
        let mut registry = NativeWindowRegistry::default();
        let id = firefox_plan().texture_id;
        assert!(!registry.handles_texture(id));
        registry.upsert(firefox_plan()).unwrap();
        assert!(registry.handles_texture(id));
        for source in [0, 1, -1, i64::MAX, i64::MAX - 1, id + 1] {
            assert!(!registry.handles_texture(source), "source ID {source}");
        }
        registry.remove(id);
        assert!(!registry.handles_texture(id));
    }

    #[test]
    fn registry_bounds_live_plans_and_never_wraps_geometry_revision() {
        let mut registry = NativeWindowRegistry::default();
        for id in 1..=MAX_NATIVE_WINDOW_PLANS as u64 {
            let mut plan = firefox_plan();
            plan.window_id = id;
            plan.texture_id = (NATIVE_WINDOW_TEXTURE_NAMESPACE | id) as i64;
            assert!(registry.upsert(plan).is_some());
        }
        let mut extra = firefox_plan();
        extra.window_id = 500;
        extra.texture_id = (NATIVE_WINDOW_TEXTURE_NAMESPACE | 500) as i64;
        assert!(registry.upsert(extra.clone()).is_none());
        registry.remove((NATIVE_WINDOW_TEXTURE_NAMESPACE | 1) as i64);
        registry.next_revision = u64::MAX;
        assert!(registry.upsert(extra).is_none());
    }
}
