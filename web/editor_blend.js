/* Luma Studio's WebGL 1 compositor. No framework or network dependency.
 * Each pass reads the previous result and one straight-alpha layer into a
 * separate framebuffer; source and destination textures never alias.
 */
(() => {
  'use strict';
  const modes = Object.freeze({
    normal: 0, multiply: 1, screen: 2, overlay: 3, darken: 4,
    lighten: 5, difference: 6, add: 7, plus: 7,
  });
  const vertexSource = `
    attribute vec2 a_position;
    varying vec2 v_uv;
    void main() {
      v_uv = (a_position + 1.0) * 0.5;
      gl_Position = vec4(a_position, 0.0, 1.0);
    }`;
  const fragmentSource = `
    precision highp float;
    varying vec2 v_uv;
    uniform sampler2D u_backdrop;
    uniform sampler2D u_source;
    uniform float u_opacity;
    uniform int u_mode;
    vec3 blend(vec3 b, vec3 s) {
      if (u_mode == 1) return b * s;
      if (u_mode == 2) return b + s - b * s;
      if (u_mode == 3) {
        return mix(2.0 * b * s,
          1.0 - 2.0 * (1.0 - b) * (1.0 - s), step(0.5, b));
      }
      if (u_mode == 4) return min(b, s);
      if (u_mode == 5) return max(b, s);
      if (u_mode == 6) return abs(b - s);
      return s;
    }
    void main() {
      vec4 b = texture2D(u_backdrop, v_uv);
      vec4 s = texture2D(u_source, v_uv);
      s.a *= u_opacity;
      float a = s.a + b.a * (1.0 - s.a);
      vec3 premultiplied = s.a * (1.0 - b.a) * s.rgb
        + s.a * b.a * blend(b.rgb, s.rgb)
        + (1.0 - s.a) * b.a * b.rgb;
      if (u_mode == 7) {
        a = min(1.0, b.a + s.a);
        premultiplied = min(vec3(1.0), b.rgb * b.a + s.rgb * s.a);
      }
      gl_FragColor = vec4(a > 0.0 ? premultiplied / a : vec3(0.0), a);
    }`;

  let renderer;
  function createRenderer() {
    const canvas = document.createElement('canvas');
    const gl = canvas.getContext('webgl', {
      alpha: true, premultipliedAlpha: false, antialias: false,
      depth: false, stencil: false, preserveDrawingBuffer: false,
    });
    if (!gl) return null;
    canvas.addEventListener('webglcontextlost', event => event.preventDefault());
    canvas.addEventListener('webglcontextrestored', () => { renderer = undefined; });
    function compile(type, source) {
      const shader = gl.createShader(type);
      gl.shaderSource(shader, source);
      gl.compileShader(shader);
      if (!gl.getShaderParameter(shader, gl.COMPILE_STATUS)) {
        const error = gl.getShaderInfoLog(shader);
        gl.deleteShader(shader);
        throw new Error(error);
      }
      return shader;
    }
    const precision = gl.getShaderPrecisionFormat(gl.FRAGMENT_SHADER, gl.HIGH_FLOAT);
    const fragment = precision && precision.precision > 0
      ? fragmentSource : fragmentSource.replace('highp', 'mediump');
    const vertexShader = compile(gl.VERTEX_SHADER, vertexSource);
    const fragmentShader = compile(gl.FRAGMENT_SHADER, fragment);
    const program = gl.createProgram();
    gl.attachShader(program, vertexShader);
    gl.attachShader(program, fragmentShader);
    gl.linkProgram(program);
    gl.deleteShader(vertexShader);
    gl.deleteShader(fragmentShader);
    if (!gl.getProgramParameter(program, gl.LINK_STATUS)) {
      const error = gl.getProgramInfoLog(program);
      gl.deleteProgram(program);
      throw new Error(error);
    }
    const quad = gl.createBuffer();
    gl.bindBuffer(gl.ARRAY_BUFFER, quad);
    gl.bufferData(gl.ARRAY_BUFFER,
      new Float32Array([-1, -1, 1, -1, -1, 1, 1, 1]), gl.STATIC_DRAW);
    return {canvas, gl, program, quad,
      position: gl.getAttribLocation(program, 'a_position'),
      backdrop: gl.getUniformLocation(program, 'u_backdrop'),
      source: gl.getUniformLocation(program, 'u_source'),
      opacity: gl.getUniformLocation(program, 'u_opacity'),
      mode: gl.getUniformLocation(program, 'u_mode'),
    };
  }

  function available() {
    try {
      if (renderer === undefined) renderer = createRenderer();
      return !!renderer && !renderer.gl.isContextLost();
    } catch (_) {
      renderer = null;
      return false;
    }
  }

  // A session consumes one layer at a time. The caller can release its raster
  // and readback bytes immediately after add(), instead of retaining L full
  // document buffers while composing L layers.
  function begin(width, height) {
    if (!available()) return null;
    const r = renderer;
    const gl = r.gl;
    const maxSize = gl.getParameter(gl.MAX_TEXTURE_SIZE);
    if (!Number.isInteger(width) || !Number.isInteger(height)
      || width < 1 || height < 1 || width > maxSize || height > maxSize) return null;
    const byteCount = width * height * 4;
    const textures = [];
    const framebuffers = [];
    function texture(data) {
      const result = gl.createTexture();
      textures.push(result);
      gl.bindTexture(gl.TEXTURE_2D, result);
      gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_MIN_FILTER, gl.NEAREST);
      gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_MAG_FILTER, gl.NEAREST);
      gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_WRAP_S, gl.CLAMP_TO_EDGE);
      gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_WRAP_T, gl.CLAMP_TO_EDGE);
      gl.texImage2D(gl.TEXTURE_2D, 0, gl.RGBA, width, height, 0,
        gl.RGBA, gl.UNSIGNED_BYTE, data);
      return result;
    }
    function framebuffer(texture) {
      const result = gl.createFramebuffer();
      framebuffers.push(result);
      gl.bindFramebuffer(gl.FRAMEBUFFER, result);
      gl.framebufferTexture2D(gl.FRAMEBUFFER, gl.COLOR_ATTACHMENT0,
        gl.TEXTURE_2D, texture, 0);
      if (gl.checkFramebufferStatus(gl.FRAMEBUFFER) !== gl.FRAMEBUFFER_COMPLETE)
        throw new Error('WebGL framebuffer is incomplete.');
      return result;
    }
    let current = 0;
    let disposed = false;
    let failed = false;
    let targets, buffers, source;
    function configure() {
      gl.useProgram(r.program);
      gl.disable(gl.BLEND);
      gl.disable(gl.DITHER);
      gl.viewport(0, 0, width, height);
      gl.pixelStorei(gl.UNPACK_PREMULTIPLY_ALPHA_WEBGL, false);
      gl.pixelStorei(gl.UNPACK_FLIP_Y_WEBGL, false);
      gl.bindBuffer(gl.ARRAY_BUFFER, r.quad);
      gl.enableVertexAttribArray(r.position);
      gl.vertexAttribPointer(r.position, 2, gl.FLOAT, false, 0, 0);
      gl.uniform1i(r.backdrop, 0);
      gl.uniform1i(r.source, 1);
    }
    function dispose() {
      if (disposed) return;
      disposed = true;
      gl.bindFramebuffer(gl.FRAMEBUFFER, null);
      for (const value of framebuffers) gl.deleteFramebuffer(value);
      for (const value of textures) gl.deleteTexture(value);
    }
    try {
      configure();
      targets = [texture(null), texture(null)];
      buffers = targets.map(framebuffer);
      source = texture(null);
      gl.bindFramebuffer(gl.FRAMEBUFFER, buffers[0]);
      gl.clearColor(0, 0, 0, 0);
      gl.clear(gl.COLOR_BUFFER_BIT);
      if (gl.getError() !== gl.NO_ERROR) throw new Error('WebGL allocation failed.');
    } catch (_) {
      dispose();
      return null;
    }
    function add(layer) {
      if (disposed || failed || renderer !== r || gl.isContextLost()) return false;
      if (!(layer.rgba instanceof Uint8Array) || layer.rgba.length !== byteCount) {
        failed = true;
        return false;
      }
      try {
        const opacity = Math.max(0, Math.min(1, Number(layer.opacity)));
        if (!Number.isFinite(opacity) || opacity === 0) return true;
        // Export and preview sessions may interleave across Dart awaits.
        // Restore all shared GL state for every pass.
        configure();
        gl.bindFramebuffer(gl.FRAMEBUFFER, buffers[1 - current]);
        gl.activeTexture(gl.TEXTURE0);
        gl.bindTexture(gl.TEXTURE_2D, targets[current]);
        gl.activeTexture(gl.TEXTURE1);
        gl.bindTexture(gl.TEXTURE_2D, source);
        gl.texSubImage2D(gl.TEXTURE_2D, 0, 0, 0, width, height,
          gl.RGBA, gl.UNSIGNED_BYTE, layer.rgba);
        gl.uniform1f(r.opacity, opacity);
        gl.uniform1i(r.mode, modes[layer.blendMode] ?? 0);
        gl.drawArrays(gl.TRIANGLE_STRIP, 0, 4);
        current = 1 - current;
        failed = gl.getError() !== gl.NO_ERROR;
        return !failed;
      } catch (_) {
        failed = true;
        return false;
      }
    }
    function finish() {
      if (disposed) return null;
      try {
        if (failed || renderer !== r || gl.isContextLost()) return null;
        gl.bindFramebuffer(gl.FRAMEBUFFER, buffers[current]);
        const output = new Uint8Array(byteCount);
        // Upload and readback use the same row order, without a Y flip.
        gl.readPixels(0, 0, width, height, gl.RGBA, gl.UNSIGNED_BYTE, output);
        return gl.getError() === gl.NO_ERROR ? output : null;
      } catch (_) {
        return null;
      } finally {
        dispose();
      }
    }
    return Object.freeze({add, finish, dispose});
  }

  function composite(width, height, layers) {
    const session = begin(width, height);
    if (!session) return null;
    try {
      for (const layer of layers) {
        if (!session.add(layer)) return null;
      }
      return session.finish();
    } finally {
      session.dispose();
    }
  }
  window.lumaBlend = Object.freeze({available, begin, composite});
})();
