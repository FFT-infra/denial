//! Runtime display policy layered over the saved output preferences.
//!
//! `outputs.conf` records which outputs the user wants lit. This policy
//! decides which connected outputs are lit right now. A closed lid covers the
//! built-in panels, and unplugging every preferred output must not leave the
//! desktop dark while another connected output could show it. These decisions
//! are never saved: once a preferred output returns or the lid opens, the
//! saved preferences apply again unchanged.

use std::collections::BTreeSet;

use tracing::{info, warn};

/// Built-in panels share the lid with the keyboard deck.
pub(super) fn is_internal_panel(name: &str) -> bool {
    name.starts_with("DSI-") || name.starts_with("eDP-") || name.starts_with("LVDS-")
}

/// How the lit outputs relate to the saved preferences.
#[derive(Clone, Debug, Eq, PartialEq)]
pub(super) enum OutputPolicy {
    /// The saved preferences decide every lit output.
    Preferred,
    /// The closed lid covers these built-in panels while another preferred
    /// output stays lit.
    Clamshell { covered: Vec<String> },
    /// The saved preferences disable every connected output, so this one
    /// stays lit until a preferred output returns.
    Fallback { output: String },
    /// The saved preferences disable every connected output, and the closed
    /// lid covers each remaining candidate.
    Covered,
}

#[cfg(feature = "flutter")]
impl OutputPolicy {
    /// Whether this policy, rather than the connector and the saved
    /// preferences, decides if `output` is lit.
    pub(super) fn overrides(&self, output: &str) -> bool {
        match self {
            Self::Clamshell { covered } => covered.iter().any(|name| name == output),
            Self::Fallback { output: fallback } => fallback == output,
            Self::Preferred | Self::Covered => false,
        }
    }
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub(super) struct OutputSelection {
    pub(super) lit: BTreeSet<String>,
    /// Connected outputs left off, in connector order.
    pub(super) unlit: Vec<String>,
    pub(super) policy: OutputPolicy,
}

/// Chooses which `connected` outputs are lit.
///
/// Preferred outputs are lit, except built-in panels under a closed lid while
/// another preferred output stays lit. When the preferences disable every
/// connected output, one output is lit anyway. A built-in panel the user can
/// see comes first, because a disabled external output may be a switched-off
/// TV, a projector, or a capture device. Any external output comes next. A
/// panel under a closed lid is never chosen; nothing is lit until the lid
/// opens or another output appears.
pub(super) fn select_outputs<'a>(
    connected: impl IntoIterator<Item = &'a str>,
    disabled: &BTreeSet<String>,
    lid_closed: bool,
) -> OutputSelection {
    let connected = connected.into_iter().collect::<Vec<_>>();
    let preferred = connected
        .iter()
        .copied()
        .filter(|name| !disabled.contains(*name))
        .collect::<Vec<_>>();

    let (lit, policy) = if preferred.is_empty() {
        let visible_panel = connected
            .iter()
            .find(|name| is_internal_panel(name) && !lid_closed);
        let external = connected.iter().find(|name| !is_internal_panel(name));
        match visible_panel.or(external) {
            Some(output) => (
                vec![*output],
                OutputPolicy::Fallback {
                    output: (*output).to_owned(),
                },
            ),
            None if connected.is_empty() => (Vec::new(), OutputPolicy::Preferred),
            None => (Vec::new(), OutputPolicy::Covered),
        }
    } else {
        let covered = preferred
            .iter()
            .copied()
            .filter(|name| lid_closed && is_internal_panel(name))
            .collect::<Vec<_>>();
        if covered.is_empty() || covered.len() == preferred.len() {
            (preferred, OutputPolicy::Preferred)
        } else {
            let lit = preferred
                .into_iter()
                .filter(|name| !covered.contains(name))
                .collect();
            let covered = covered.into_iter().map(str::to_owned).collect();
            (lit, OutputPolicy::Clamshell { covered })
        }
    };

    let lit = lit.into_iter().map(str::to_owned).collect::<BTreeSet<_>>();
    let unlit = connected
        .into_iter()
        .filter(|name| !lit.contains(*name))
        .map(str::to_owned)
        .collect();
    OutputSelection { lit, unlit, policy }
}

/// Updates the saved preferences so that they light the `requested` outputs.
///
/// Settings submits the outputs it shows as lit. That list includes a
/// fallback output and leaves out panels under the closed lid, so copying it
/// would save those transient states as preferences. A preference changes
/// only where the current preferences would not light the submitted layout.
/// The comparison repeats because one change can end a fallback or a
/// clamshell. A panel under the closed lid stays unlit whatever its
/// preference.
#[cfg(feature = "flutter")]
pub(super) fn reconcile_disabled_outputs(
    connected: &[&str],
    disabled: &BTreeSet<String>,
    lid_closed: bool,
    requested: impl Fn(&str) -> bool,
) -> BTreeSet<String> {
    let mut disabled = disabled.clone();
    // Each pass only moves preferences to their requested value, so every
    // preference changes at most once and the loop ends.
    loop {
        let lit = select_outputs(connected.iter().copied(), &disabled, lid_closed).lit;
        let mut changed = false;
        for &name in connected {
            let wanted = requested(name);
            if wanted == lit.contains(name) {
                continue;
            }
            changed |= if wanted {
                disabled.remove(name)
            } else {
                disabled.insert(name.to_owned())
            };
        }
        if !changed {
            return disabled;
        }
    }
}

/// Reports each change of the display policy once, instead of on every
/// connector rescan.
#[derive(Debug, Default)]
pub(super) struct OutputPolicyJournal {
    reported: Option<OutputSelection>,
}

impl OutputPolicyJournal {
    pub(super) fn record(&mut self, selection: &OutputSelection) {
        let previous = self.reported.replace(selection.clone());
        let previous = previous.as_ref();
        if previous.is_some_and(|previous| {
            previous.policy == selection.policy && previous.unlit == selection.unlit
        }) {
            return;
        }
        match &selection.policy {
            OutputPolicy::Preferred => {
                if previous.is_some_and(|previous| previous.policy != OutputPolicy::Preferred) {
                    info!("the saved display preferences apply again");
                }
                if !selection.unlit.is_empty() {
                    info!(
                        off = ?selection.unlit,
                        "leaving connected displays off as the saved preferences ask"
                    );
                }
            }
            OutputPolicy::Clamshell { covered } => info!(
                ?covered,
                "the lid is closed; turning off the built-in panel while another display stays on"
            ),
            OutputPolicy::Fallback { output } => warn!(
                output,
                "the saved preferences turn off every connected display; \
                 keeping this one on until a preferred display returns"
            ),
            OutputPolicy::Covered => warn!(
                off = ?selection.unlit,
                "the saved preferences turn off every connected display and the lid \
                 covers the built-in panel; waiting for the lid to open or another display"
            ),
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn names(names: &[&str]) -> BTreeSet<String> {
        names.iter().map(|name| (*name).to_owned()).collect()
    }

    #[test]
    fn unplugging_the_preferred_display_lights_the_disabled_panel() {
        let selection = select_outputs(["DSI-1"], &names(&["DSI-1"]), false);
        assert_eq!(selection.lit, names(&["DSI-1"]));
        assert_eq!(
            selection.policy,
            OutputPolicy::Fallback {
                output: "DSI-1".to_owned()
            }
        );
    }

    #[test]
    fn a_connected_preferred_display_leaves_disabled_outputs_off() {
        let selection = select_outputs(["DP-1", "DSI-1"], &names(&["DSI-1"]), false);
        assert_eq!(selection.lit, names(&["DP-1"]));
        assert_eq!(selection.unlit, ["DSI-1"]);
        assert_eq!(selection.policy, OutputPolicy::Preferred);
    }

    #[test]
    fn fallback_prefers_a_visible_panel_over_an_external_display() {
        let selection =
            select_outputs(["HDMI-A-1", "eDP-1"], &names(&["HDMI-A-1", "eDP-1"]), false);
        assert_eq!(selection.lit, names(&["eDP-1"]));
    }

    #[test]
    fn fallback_uses_an_external_display_when_the_lid_covers_the_panel() {
        let selection = select_outputs(["HDMI-A-1", "eDP-1"], &names(&["HDMI-A-1", "eDP-1"]), true);
        assert_eq!(selection.lit, names(&["HDMI-A-1"]));
    }

    #[test]
    fn a_covered_panel_is_never_lit_as_a_fallback() {
        let selection = select_outputs(["eDP-1"], &names(&["eDP-1"]), true);
        assert!(selection.lit.is_empty());
        assert_eq!(selection.policy, OutputPolicy::Covered);
    }

    #[test]
    fn no_connected_output_is_not_a_policy_override() {
        let selection = select_outputs(std::iter::empty(), &names(&["DSI-1"]), false);
        assert!(selection.lit.is_empty());
        assert_eq!(selection.policy, OutputPolicy::Preferred);
    }

    #[test]
    fn closing_the_lid_turns_off_the_panel_only_while_another_display_stays_on() {
        let docked = select_outputs(["DP-1", "eDP-1"], &names(&[]), true);
        assert_eq!(docked.lit, names(&["DP-1"]));
        assert_eq!(
            docked.policy,
            OutputPolicy::Clamshell {
                covered: vec!["eDP-1".to_owned()]
            }
        );

        let undocked = select_outputs(["eDP-1"], &names(&[]), true);
        assert_eq!(undocked.lit, names(&["eDP-1"]));
        assert_eq!(undocked.policy, OutputPolicy::Preferred);

        let external_disabled = select_outputs(["DP-1", "eDP-1"], &names(&["DP-1"]), true);
        assert_eq!(external_disabled.lit, names(&["eDP-1"]));
    }

    #[cfg(feature = "flutter")]
    #[test]
    fn only_the_fallback_and_covered_panels_are_decided_by_policy() {
        let docked = select_outputs(["DP-1", "eDP-1"], &names(&[]), true);
        assert!(docked.policy.overrides("eDP-1"));
        assert!(!docked.policy.overrides("DP-1"));

        let fallback = select_outputs(["DSI-1"], &names(&["DSI-1"]), false);
        assert!(fallback.policy.overrides("DSI-1"));

        let preferred = select_outputs(["DP-1", "DSI-1"], &names(&["DSI-1"]), false);
        assert!(!preferred.policy.overrides("DSI-1"));
    }

    #[cfg(feature = "flutter")]
    #[test]
    fn settings_changes_during_a_fallback_keep_the_saved_preference() {
        let saved = names(&["DSI-1"]);
        let reconciled = reconcile_disabled_outputs(&["DSI-1"], &saved, false, |_| true);
        assert_eq!(reconciled, saved);
    }

    #[cfg(feature = "flutter")]
    #[test]
    fn settings_changes_in_clamshell_mode_keep_the_panel_enabled() {
        let reconciled =
            reconcile_disabled_outputs(&["DP-1", "eDP-1"], &names(&[]), true, |name| {
                name == "DP-1"
            });
        assert!(reconciled.is_empty());
    }

    #[cfg(feature = "flutter")]
    #[test]
    fn enabling_another_display_during_a_fallback_keeps_the_fallback_lit() {
        let reconciled = reconcile_disabled_outputs(
            &["DSI-1", "HDMI-A-1"],
            &names(&["DSI-1", "HDMI-A-1"]),
            false,
            |_| true,
        );
        assert!(reconciled.is_empty());
    }

    #[cfg(feature = "flutter")]
    #[test]
    fn explicit_toggles_become_saved_preferences() {
        let reconciled =
            reconcile_disabled_outputs(&["DP-1", "DSI-1"], &names(&[]), false, |name| {
                name == "DP-1"
            });
        assert_eq!(reconciled, names(&["DSI-1"]));

        let reconciled =
            reconcile_disabled_outputs(&["DP-1", "DSI-1"], &names(&["DSI-1"]), false, |_| true);
        assert!(reconciled.is_empty());
    }
}
