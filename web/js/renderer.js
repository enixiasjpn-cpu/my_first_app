// カメラ映像 → 切り抜き → フィルター → 時刻文字 を WebGL で1枚の canvas に描画する。
// この canvas がそのままプレビューになり、録画（captureStream）・写真にも使われるので、
// 画面で見えているものと保存されるものが必ず一致する。

import { FILTERS } from './filters.js';

const VERTEX = `
attribute vec2 a_pos;
varying vec2 v_uv;
void main() {
  v_uv = a_pos * 0.5 + 0.5;
  gl_Position = vec4(a_pos, 0.0, 1.0);
}`;

function fragmentSource() {
  const filterFunctions = FILTERS.map((f) => f.glsl).join('\n');
  const filterSwitch = FILTERS.map((f, i) => `if (u_filter == ${i}) c = ${f.fn}(c, uv, src);`).join('\n  ');
  return `
precision highp float;
varying vec2 v_uv;
uniform sampler2D u_video;
uniform sampler2D u_text;
uniform vec4 u_crop;      // 元映像の切り抜き範囲 (x, y, w, h)  0..1
uniform float u_mirror;
uniform int u_filter;
uniform float u_hasText;
uniform vec2 u_res;       // 出力解像度
uniform vec2 u_srcTexel;  // 元映像 1px の大きさ (uv)
uniform float u_seed;

vec3 sampleVideo(vec2 p) { return texture2D(u_video, p).rgb; }

${filterFunctions}

void main() {
  vec2 uv = v_uv;
  float x = u_mirror > 0.5 ? 1.0 - uv.x : uv.x;
  vec2 src = u_crop.xy + vec2(x, uv.y) * u_crop.zw;
  vec3 c = sampleVideo(src);
  ${filterSwitch}
  if (u_hasText > 0.5) {
    vec4 t = texture2D(u_text, uv);
    c = mix(c, t.rgb, t.a);
  }
  gl_FragColor = vec4(c, 1.0);
}`;
}

function compile(gl, type, source) {
  const shader = gl.createShader(type);
  gl.shaderSource(shader, source);
  gl.compileShader(shader);
  if (!gl.getShaderParameter(shader, gl.COMPILE_STATUS)) {
    throw new Error(gl.getShaderInfoLog(shader) || 'shader compile error');
  }
  return shader;
}

function makeTexture(gl) {
  const texture = gl.createTexture();
  gl.bindTexture(gl.TEXTURE_2D, texture);
  gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_MIN_FILTER, gl.LINEAR);
  gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_MAG_FILTER, gl.LINEAR);
  gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_WRAP_S, gl.CLAMP_TO_EDGE);
  gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_WRAP_T, gl.CLAMP_TO_EDGE);
  return texture;
}

export class FrameRenderer {
  constructor(canvas) {
    this.canvas = canvas;
    const gl = canvas.getContext('webgl', {
      alpha: false,
      antialias: false,
      premultipliedAlpha: false,
      preserveDrawingBuffer: true,
    });
    if (!gl) throw new Error('WebGL が使えません');
    this.gl = gl;

    const program = gl.createProgram();
    gl.attachShader(program, compile(gl, gl.VERTEX_SHADER, VERTEX));
    gl.attachShader(program, compile(gl, gl.FRAGMENT_SHADER, fragmentSource()));
    gl.linkProgram(program);
    if (!gl.getProgramParameter(program, gl.LINK_STATUS)) {
      throw new Error(gl.getProgramInfoLog(program) || 'program link error');
    }
    gl.useProgram(program);
    this.program = program;

    const buffer = gl.createBuffer();
    gl.bindBuffer(gl.ARRAY_BUFFER, buffer);
    gl.bufferData(gl.ARRAY_BUFFER, new Float32Array([-1, -1, 1, -1, -1, 1, 1, 1]), gl.STATIC_DRAW);
    const loc = gl.getAttribLocation(program, 'a_pos');
    gl.enableVertexAttribArray(loc);
    gl.vertexAttribPointer(loc, 2, gl.FLOAT, false, 0, 0);

    this.u = {};
    for (const name of ['u_video', 'u_text', 'u_crop', 'u_mirror', 'u_filter', 'u_hasText', 'u_res', 'u_srcTexel', 'u_seed']) {
      this.u[name] = gl.getUniformLocation(program, name);
    }

    gl.pixelStorei(gl.UNPACK_FLIP_Y_WEBGL, true);
    this.videoTexture = makeTexture(gl);
    this.textTexture = makeTexture(gl);
    gl.uniform1i(this.u.u_video, 0);
    gl.uniform1i(this.u.u_text, 1);

    this.textCanvas = document.createElement('canvas');
    this.currentText = null;
    this.currentTextSize = '';
  }

  setSize(width, height) {
    if (this.canvas.width !== width || this.canvas.height !== height) {
      this.canvas.width = width;
      this.canvas.height = height;
      this.currentText = null; // 文字画像を作り直す
    }
  }

  /** 時刻文字の画像を作ってテクスチャに送る（文字やサイズが変わった時だけ） */
  updateText(text) {
    const size = `${this.canvas.width}x${this.canvas.height}`;
    if (text === this.currentText && size === this.currentTextSize) return;
    this.currentText = text;
    this.currentTextSize = size;
    if (!text) return;

    const w = this.canvas.width;
    const h = this.canvas.height;
    const tc = this.textCanvas;
    tc.width = w;
    tc.height = h;
    const ctx = tc.getContext('2d');
    ctx.clearRect(0, 0, w, h);
    const fontSize = Math.round(Math.min(w, h) * 0.2);
    ctx.font = `600 ${fontSize}px -apple-system, "SF Pro Display", "Helvetica Neue", "Hiragino Sans", Arial, sans-serif`;
    ctx.textAlign = 'center';
    ctx.textBaseline = 'middle';
    ctx.fillStyle = '#ffffff';
    ctx.shadowColor = 'rgba(0, 0, 0, 0.25)';
    ctx.shadowBlur = fontSize * 0.08;
    ctx.fillText(text, w / 2, h / 2);

    const gl = this.gl;
    gl.activeTexture(gl.TEXTURE1);
    gl.bindTexture(gl.TEXTURE_2D, this.textTexture);
    gl.texImage2D(gl.TEXTURE_2D, 0, gl.RGBA, gl.RGBA, gl.UNSIGNED_BYTE, tc);
  }

  /**
   * @param {HTMLVideoElement} video
   * @param {{filter:number, text:string|null, mirror:boolean, zoom:number}} opts
   */
  render(video, opts) {
    const vw = video.videoWidth;
    const vh = video.videoHeight;
    if (!vw || !vh) return false;

    const gl = this.gl;
    const w = this.canvas.width;
    const h = this.canvas.height;
    gl.viewport(0, 0, w, h);

    gl.activeTexture(gl.TEXTURE0);
    gl.bindTexture(gl.TEXTURE_2D, this.videoTexture);
    gl.texImage2D(gl.TEXTURE_2D, 0, gl.RGB, gl.RGB, gl.UNSIGNED_BYTE, video);

    this.updateText(opts.text);
    gl.activeTexture(gl.TEXTURE1);
    gl.bindTexture(gl.TEXTURE_2D, this.textTexture);

    // 出力の比率で中央を切り抜く（＋デジタルズーム）
    const srcAspect = vw / vh;
    const outAspect = w / h;
    let cw = 1;
    let ch = 1;
    if (srcAspect > outAspect) cw = outAspect / srcAspect;
    else ch = srcAspect / outAspect;
    const zoom = Math.max(1, opts.zoom || 1);
    cw /= zoom;
    ch /= zoom;

    gl.uniform4f(this.u.u_crop, (1 - cw) / 2, (1 - ch) / 2, cw, ch);
    gl.uniform1f(this.u.u_mirror, opts.mirror ? 1 : 0);
    gl.uniform1i(this.u.u_filter, opts.filter || 0);
    gl.uniform1f(this.u.u_hasText, opts.text ? 1 : 0);
    gl.uniform2f(this.u.u_res, w, h);
    gl.uniform2f(this.u.u_srcTexel, 1 / vw, 1 / vh);
    gl.uniform1f(this.u.u_seed, Math.random() * 100);
    gl.drawArrays(gl.TRIANGLE_STRIP, 0, 4);
    return true;
  }
}
