// The one shader of the wgpu device: instanced quads, each laid over what
// is already drawn.
//
// It states the same arithmetic as `blend.rs` (`source` and `blend`), and
// the two are kept alike by hand: a change to one is a change to the
// other. A quad's pixel is a colour in linear light and a coverage for
// each of red, green, blue and alpha, and
//
//     out = colour * coverage + under * (1 - coverage)
//
// for each channel. The target is an sRGB format, so the GPU makes what
// is under linear before blending and encodes the result after.
//
// The fragment's output is one of two, put before this text when the
// module is made (`gpu.rs`): with dual-source blending the colour times
// its coverage as one source and the coverages as the other, so each
// channel is blended by its own; without it, one coverage for the three.

struct Globals {
    // The target's size in pixels.
    size: vec2<f32>,
    // How much the coverage of dark text is raised: `blend::CONTRAST`.
    contrast: f32,
    unused: f32,
}

@group(0) @binding(0) var<uniform> globals: Globals;
// The atlas page the quads of a batch read; a fill reads none of it.
@group(1) @binding(0) var page: texture_2d<f32>;

struct Quad {
    // Left, top, width and height on the target, in pixels.
    @location(0) box: vec4<i32>,
    // The left and the top of its rectangle in the page, then its kind:
    // 0 a fill, 1 a mask, 2 a subpixel mask, 3 a colour image.
    @location(1) source: vec4<u32>,
    // Its colour: sRGB values and an alpha, each from 0 to 1.
    @location(2) color: vec4<f32>,
}

struct Varying {
    @builtin(position) position: vec4<f32>,
    @location(0) @interpolate(flat) corner: vec2<i32>,
    @location(1) @interpolate(flat) source: vec4<u32>,
    @location(2) @interpolate(flat) color: vec4<f32>,
}

@vertex
fn vertex(@builtin(vertex_index) index: u32, quad: Quad) -> Varying {
    // The four corners of a strip: left top, right top, left bottom,
    // right bottom.
    let along = vec2<f32>(f32(index & 1u), f32((index >> 1u) & 1u));
    let pixel = vec2<f32>(quad.box.xy) + along * vec2<f32>(quad.box.zw);
    var out: Varying;
    out.position = vec4<f32>(
        pixel.x / globals.size.x * 2.0 - 1.0,
        1.0 - pixel.y / globals.size.y * 2.0,
        0.0,
        1.0,
    );
    out.corner = quad.box.xy;
    out.source = quad.source;
    out.color = quad.color;
    return out;
}

// The linear-light value of an sRGB value: `blend::to_linear`.
fn to_linear(encoded: vec3<f32>) -> vec3<f32> {
    let low = encoded / 12.92;
    let high = pow((encoded + vec3<f32>(0.055)) / 1.055, vec3<f32>(2.4));
    return select(high, low, encoded <= vec3<f32>(0.04045));
}

// A coverage raised for dark text: `blend::adjusted`.
fn adjusted(coverage: f32, luminance: f32) -> f32 {
    return coverage + globals.contrast * (1.0 - luminance) * coverage * (1.0 - coverage);
}

// What a quad lays over one pixel: `blend::Source`.
struct Laid {
    rgb: vec3<f32>,
    coverage: vec4<f32>,
}

// `blend::source`.
fn laid(in: Varying) -> Laid {
    let within = vec2<i32>(floor(in.position.xy)) - in.corner;
    let texel = textureLoad(page, vec2<i32>(in.source.xy) + within, 0);
    var rgb = to_linear(in.color.rgb);
    let alpha = in.color.a;
    let luminance = dot(rgb, vec3<f32>(0.2126, 0.7152, 0.0722));
    var coverage = vec4<f32>(alpha);
    switch in.source.z {
        case 1u {
            coverage = vec4<f32>(adjusted(texel.r, luminance) * alpha);
        }
        case 2u {
            let each = vec3<f32>(
                adjusted(texel.r, luminance),
                adjusted(texel.g, luminance),
                adjusted(texel.b, luminance),
            ) * alpha;
            coverage = vec4<f32>(each, (each.r + each.g + each.b) / 3.0);
        }
        case 3u {
            // The image's colours are multiplied by its alpha, as sRGB
            // values: divided out before they are made linear.
            coverage = vec4<f32>(texel.a);
            rgb = vec3<f32>(0.0);
            if texel.a > 0.0 {
                let own = round(texel.rgb / texel.a * 255.0) / 255.0;
                rgb = to_linear(min(own, vec3<f32>(1.0)));
            }
        }
        default {}
    }
    return Laid(rgb, coverage);
}
