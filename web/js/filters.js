// フィルター一覧。
// 追加するときは、この配列に { name, fn, glsl } を1つ足すだけでよい。
// glsl には `vec3 <fn>(vec3 c, vec2 uv, vec2 src)` を書く。
//   c   : 元の色 / uv : 出力上の位置(0..1) / src : 元映像上の位置
//   使える値: sampleVideo(p), u_res, u_srcTexel, u_seed

export const FILTERS = [
  {
    name: 'NORMAL',
    fn: 'filterNormal',
    glsl: `
vec3 filterNormal(vec3 c, vec2 uv, vec2 src) {
  return c;
}`,
  },
  {
    // インスタント / フィルムカメラ風。やりすぎない程度に：
    // ほんの少し甘く、色あせ、黒の浮き、暖色寄り、軽い周辺減光、控えめな粒子
    name: 'RETRO',
    fn: 'filterRetro',
    glsl: `
float retroHash(vec2 p) {
  return fract(sin(dot(p, vec2(12.9898, 78.233))) * 43758.5453);
}
vec3 filterRetro(vec3 c, vec2 uv, vec2 src) {
  // ほんの少し甘く
  vec2 o = u_srcTexel * 0.9;
  c = (c * 2.0
       + sampleVideo(src + vec2(o.x, 0.0)) + sampleVideo(src - vec2(o.x, 0.0))
       + sampleVideo(src + vec2(0.0, o.y)) + sampleVideo(src - vec2(0.0, o.y))) / 6.0;
  // 彩度とコントラストを少し落とす
  float l = dot(c, vec3(0.299, 0.587, 0.114));
  c = mix(vec3(l), c, 0.78);
  c = (c - 0.5) * 0.95 + 0.5;
  // 黒を少し持ち上げ、白を少し抑える
  c = 0.06 + c * 0.89;
  // わずかに暖色、シャドウにほんのり青み
  c *= vec3(1.04, 1.0, 0.91);
  c += vec3(0.01, 0.005, 0.025);
  // 軽い周辺減光
  float d = length(uv - 0.5);
  c *= mix(0.84, 1.0, smoothstep(0.75, 0.3, d));
  // 粒子（毎フレーム変わる）
  vec2 cell = floor(uv * u_res / 1.5);
  float n = retroHash(cell + u_seed);
  c += (n - 0.5) * 0.07;
  return clamp(c, 0.0, 1.0);
}`,
  },
];
