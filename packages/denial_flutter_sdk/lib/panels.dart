enum PanelEdge {
  left,
  right,
  top,
  bottom,
  hidden;

  bool get isHorizontal => this == top || this == bottom;
}
