uniform Paint {
  vec4 color;
}
paint;

in vec3 v_position;
in vec3 v_normal;
in vec3 v_viewvector;

in vec2 v_texture_coords;

in vec4 v_color;

out vec4 frag_color;

void main() {

  // Clip to the tile's own square: [-1, 1) on both axes. Tile data reaches
  // slightly past the square, so a looser bound let neighbouring tiles blend
  // translucent layers (water, woods) twice along every seam. Half-open
  // bounds give each pixel on a shared edge to exactly one tile.
  if (v_position.x < -1.0 || v_position.x >= 1.0 ||
      v_position.y < -1.0 || v_position.y >= 1.0) {
    discard;
  }

  frag_color = paint.color;
}