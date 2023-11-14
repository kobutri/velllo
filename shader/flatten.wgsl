// SPDX-License-Identifier: Apache-2.0 OR MIT OR Unlicense

// Flatten curves to lines

#import config
#import drawtag
#import pathtag
#import segment
#import cubic
#import bump

@group(0) @binding(0)
var<uniform> config: Config;

@group(0) @binding(1)
var<storage> scene: array<u32>;

@group(0) @binding(2)
var<storage> tag_monoids: array<TagMonoid>;

struct AtomicPathBbox {
    x0: atomic<i32>,
    y0: atomic<i32>,
    x1: atomic<i32>,
    y1: atomic<i32>,
    draw_flags: u32,
    trans_ix: u32,
}

@group(0) @binding(3)
var<storage, read_write> path_bboxes: array<AtomicPathBbox>;

@group(0) @binding(4)
var<storage, read_write> bump: BumpAllocators;

@group(0) @binding(5)
var<storage, read_write> lines: array<LineSoup>;

struct SubdivResult {
    val: f32,
    a0: f32,
    a2: f32,
}

let D = 0.67;
fn approx_parabola_integral(x: f32) -> f32 {
    return x * inverseSqrt(sqrt(1.0 - D + (D * D * D * D + 0.25 * x * x)));
}

let B = 0.39;
fn approx_parabola_inv_integral(x: f32) -> f32 {
    return x * sqrt(1.0 - B + (B * B + 0.5 * x * x));
}

fn estimate_subdiv(p0: vec2f, p1: vec2f, p2: vec2f, sqrt_tol: f32) -> SubdivResult {
    let d01 = p1 - p0;
    let d12 = p2 - p1;
    let dd = d01 - d12;
    let cross = (p2.x - p0.x) * dd.y - (p2.y - p0.y) * dd.x;
    let cross_inv = select(1.0 / cross, 1.0e9, abs(cross) < 1.0e-9);
    let x0 = dot(d01, dd) * cross_inv;
    let x2 = dot(d12, dd) * cross_inv;
    let scale = abs(cross / (length(dd) * (x2 - x0)));

    let a0 = approx_parabola_integral(x0);
    let a2 = approx_parabola_integral(x2);
    var val = 0.0;
    if scale < 1e9 {
        let da = abs(a2 - a0);
        let sqrt_scale = sqrt(scale);
        if sign(x0) == sign(x2) {
            val = sqrt_scale;
        } else {
            let xmin = sqrt_tol / sqrt_scale;
            val = sqrt_tol / approx_parabola_integral(xmin);
        }
        val *= da;
    }
    return SubdivResult(val, a0, a2);
}

fn eval_quad(p0: vec2f, p1: vec2f, p2: vec2f, t: f32) -> vec2f {
    let mt = 1.0 - t;
    return p0 * (mt * mt) + (p1 * (mt * 2.0) + p2 * t) * t;
}

fn eval_cubic(p0: vec2f, p1: vec2f, p2: vec2f, p3: vec2f, t: f32) -> vec2f {
    let mt = 1.0 - t;
    return p0 * (mt * mt * mt) + (p1 * (mt * mt * 3.0) + (p2 * (mt * 3.0) + p3 * t) * t) * t;
}

fn eval_quad_tangent(p0: vec2f, p1: vec2f, p2: vec2f, t: f32) -> vec2f {
    let dp0 = 2. * (p1 - p0);
    let dp1 = 2. * (p2 - p1);
    return mix(dp0, dp1, t);
}

fn eval_quad_normal(p0: vec2f, p1: vec2f, p2: vec2f, t: f32) -> vec2f {
    let tangent = normalize(eval_quad_tangent(p0, p1, p2, t));
    return vec2(-tangent.y, tangent.x);
}

fn cubic_start_tangent(p0: vec2f, p1: vec2f, p2: vec2f, p3: vec2f) -> vec2f {
    let EPS = 1e-12;
    let d01 = p1 - p0;
    let d02 = p2 - p0;
    let d03 = p3 - p0;
    return select(select(d03, d02, dot(d02, d02) > EPS), d01, dot(d01, d01) > EPS);
}

fn cubic_end_tangent(p0: vec2f, p1: vec2f, p2: vec2f, p3: vec2f) -> vec2f {
    let EPS = 1e-12;
    let d23 = p3 - p2;
    let d13 = p3 - p1;
    let d03 = p3 - p0;
    return select(select(d03, d13, dot(d13, d13) > EPS), d23, dot(d23, d23) > EPS);
}

fn cubic_start_normal(p0: vec2f, p1: vec2f, p2: vec2f, p3: vec2f) -> vec2f {
    let tangent = normalize(cubic_start_tangent(p0, p1, p2, p3));
    return vec2(-tangent.y, tangent.x);
}

fn cubic_end_normal(p0: vec2f, p1: vec2f, p2: vec2f, p3: vec2f) -> vec2f {
    let tangent = normalize(cubic_end_tangent(p0, p1, p2, p3));
    return vec2(-tangent.y, tangent.x);
}

let MAX_QUADS = 16u;

fn flatten_cubic(cubic: Cubic) {
    let p0 = cubic.p0;
    let p1 = cubic.p1;
    let p2 = cubic.p2;
    let p3 = cubic.p3;
    let err_v = 3.0 * (p2 - p1) + p0 - p3;
    let err = dot(err_v, err_v);
    let ACCURACY = 0.25;
    let Q_ACCURACY = ACCURACY * 0.1;
    let REM_ACCURACY = ACCURACY - Q_ACCURACY;
    let MAX_HYPOT2 = 432.0 * Q_ACCURACY * Q_ACCURACY;
    var n_quads = max(u32(ceil(pow(err * (1.0 / MAX_HYPOT2), 1.0 / 6.0))), 1u);
    n_quads = min(n_quads, MAX_QUADS);
    var keep_params: array<SubdivResult, MAX_QUADS>;
    var val = 0.0;
    var qp0 = p0;
    let step = 1.0 / f32(n_quads);
    for (var i = 0u; i < n_quads; i += 1u) {
        let t = f32(i + 1u) * step;
        let qp2 = eval_cubic(p0, p1, p2, p3, t);
        var qp1 = eval_cubic(p0, p1, p2, p3, t - 0.5 * step);
        qp1 = 2.0 * qp1 - 0.5 * (qp0 + qp2);

        // HACK: this increases subdivision count as a function of the stroke width for shitty
        // strokes. This isn't systematic or correct and shouldn't be relied on in the long term.
        var tol = sqrt(REM_ACCURACY);
        if cubic.flags == CUBIC_IS_STROKE {
            tol *= min(1000., dot(cubic.stroke, cubic.stroke));
        }
        let params = estimate_subdiv(qp0, qp1, qp2, tol);
        keep_params[i] = params;
        val += params.val;
        qp0 = qp2;
    }

    // HACK: normal vector used to offset line segments for shitty stroke handling.
    var n0 = cubic_start_normal(p0, p1, p2, p3) * cubic.stroke;

    let n = max(u32(ceil(val * (0.5 / sqrt(REM_ACCURACY)))), 1u);
    var lp0 = p0;
    qp0 = p0;
    let v_step = val / f32(n);
    var n_out = 1u;
    var val_sum = 0.0;
    for (var i = 0u; i < n_quads; i += 1u) {
        let t = f32(i + 1u) * step;
        let qp2 = eval_cubic(p0, p1, p2, p3, t);
        var qp1 = eval_cubic(p0, p1, p2, p3, t - 0.5 * step);
        qp1 = 2.0 * qp1 - 0.5 * (qp0 + qp2);
        let params = keep_params[i];
        let u0 = approx_parabola_inv_integral(params.a0);
        let u2 = approx_parabola_inv_integral(params.a2);
        let uscale = 1.0 / (u2 - u0);
        var val_target = f32(n_out) * v_step;
        while n_out == n || val_target < val_sum + params.val {
            var lp1: vec2f;
            var t1: f32;
            if n_out == n {
                lp1 = p3;
                t1 = 1.;
            } else {
                let u = (val_target - val_sum) / params.val;
                let a = mix(params.a0, params.a2, u);
                let au = approx_parabola_inv_integral(a);
                let t = (au - u0) * uscale;
                t1 = t;
                lp1 = eval_quad(qp0, qp1, qp2, t);
            }

            // TODO: Instead of outputting two offset segments here, restructure this function as
            // "flatten_cubic_at_offset" such that it outputs one cubic at an offset. That should
            // more closely resemble the end state of this shader which will work like a state
            // machine.
            if cubic.flags == 1u {
                var n1: vec2f;
                if all(lp1 == p3) {
                    n1 = cubic_end_normal(p0, p1, p2, p3);
                } else {
                    n1 = eval_quad_normal(qp0, qp1, qp2, t1);
                }
                n1 *= cubic.stroke;
                let line_ix = atomicAdd(&bump.lines, 2u);
                lines[line_ix]      = LineSoup(cubic.path_ix, lp0 + n0, lp1 + n1);
                lines[line_ix + 1u] = LineSoup(cubic.path_ix, lp1 - n1, lp0 - n0);
                n0 = n1;
            } else {
                // Output line segment lp0..lp1
                let line_ix = atomicAdd(&bump.lines, 1u);
                // TODO: check failure
                lines[line_ix] = LineSoup(cubic.path_ix, lp0, lp1);
            }
            n_out += 1u;
            val_target += v_step;
            lp0 = lp1;
        }
        val_sum += params.val;
        qp0 = qp2;
    }
}

var<private> pathdata_base: u32;

fn read_f32_point(ix: u32) -> vec2f {
    let x = bitcast<f32>(scene[pathdata_base + ix]);
    let y = bitcast<f32>(scene[pathdata_base + ix + 1u]);
    return vec2(x, y);
}

fn read_i16_point(ix: u32) -> vec2f {
    let raw = scene[pathdata_base + ix];
    let x = f32(i32(raw << 16u) >> 16u);
    let y = f32(i32(raw) >> 16u);
    return vec2(x, y);
}

struct Transform {
    mat: vec4f,
    translate: vec2f,
}

fn read_transform(transform_base: u32, ix: u32) -> Transform {
    let base = transform_base + ix * 6u;
    let c0 = bitcast<f32>(scene[base]);
    let c1 = bitcast<f32>(scene[base + 1u]);
    let c2 = bitcast<f32>(scene[base + 2u]);
    let c3 = bitcast<f32>(scene[base + 3u]);
    let c4 = bitcast<f32>(scene[base + 4u]);
    let c5 = bitcast<f32>(scene[base + 5u]);
    let mat = vec4(c0, c1, c2, c3);
    let translate = vec2(c4, c5);
    return Transform(mat, translate);
}

fn transform_apply(transform: Transform, p: vec2f) -> vec2f {
    return transform.mat.xy * p.x + transform.mat.zw * p.y + transform.translate;
}

fn round_down(x: f32) -> i32 {
    return i32(floor(x));
}

fn round_up(x: f32) -> i32 {
    return i32(ceil(x));
}

struct PathTagData {
    tag_byte: u32,
    monoid: TagMonoid,
}

fn compute_tag_monoid(ix: u32) -> PathTagData {
    let tag_word = scene[config.pathtag_base + (ix >> 2u)];
    let shift = (ix & 3u) * 8u;
    var tm = reduce_tag(tag_word & ((1u << shift) - 1u));
    // TODO: this can be a read buf overflow. Conditionalize by tag byte?
    tm = combine_tag_monoid(tag_monoids[ix >> 2u], tm);
    var tag_byte = (tag_word >> shift) & 0xffu;
    return PathTagData(tag_byte, tm);
}

struct CubicPoints {
    p0: vec2f,
    p1: vec2f,
    p2: vec2f,
    p3: vec2f,
}

fn read_path_segment(tag: PathTagData, transform: Transform, is_stroke: bool) -> CubicPoints {
    var p0: vec2f;
    var p1: vec2f;
    var p2: vec2f;
    var p3: vec2f;

    var seg_type = tag.tag_byte & PATH_TAG_SEG_TYPE;
    let pathseg_offset = tag.monoid.pathseg_offset;
    let is_stroke_cap_marker = is_stroke && (tag.tag_byte & PATH_TAG_SUBPATH_END) != 0u;
    let is_open = seg_type == PATH_TAG_QUADTO;

    if (tag.tag_byte & PATH_TAG_F32) != 0u {
        p0 = read_f32_point(pathseg_offset);
        p1 = read_f32_point(pathseg_offset + 2u);
        if seg_type >= PATH_TAG_QUADTO {
            p2 = read_f32_point(pathseg_offset + 4u);
            if seg_type == PATH_TAG_CUBICTO {
                p3 = read_f32_point(pathseg_offset + 6u);
            }
        }
    } else {
        p0 = read_i16_point(pathseg_offset);
        p1 = read_i16_point(pathseg_offset + 1u);
        if seg_type >= PATH_TAG_QUADTO {
            p2 = read_i16_point(pathseg_offset + 2u);
            if seg_type == PATH_TAG_CUBICTO {
                p3 = read_i16_point(pathseg_offset + 3u);
            }
        }
    }

    if is_stroke_cap_marker && is_open {
        // The stroke cap marker for an open path is encoded as a quadto where the p1 and p2 store
        // the start control point of the subpath and together with p2 forms the start tangent. p0
        // is ignored.
        //
        // This is encoded this way because encoding this as a lineto would require adding a moveto,
        // which would terminate the subpath too early (by setting the SUBPATH_END on the
        // segment preceding the cap marker). This scheme is only used for strokes.
        p0 = transform_apply(transform, p1);
        p1 = transform_apply(transform, p2);
        seg_type = PATH_TAG_LINETO;
    } else {
        p0 = transform_apply(transform, p0);
        p1 = transform_apply(transform, p1);
    }

    // Degree-raise
    if seg_type == PATH_TAG_LINETO {
        p3 = p1;
        p2 = mix(p3, p0, 1.0 / 3.0);
        p1 = mix(p0, p3, 1.0 / 3.0);
    } else if seg_type >= PATH_TAG_QUADTO {
        p2 = transform_apply(transform, p2);
        if seg_type == PATH_TAG_CUBICTO {
            p3 = transform_apply(transform, p3);
        } else {
            p3 = p2;
            p2 = mix(p1, p2, 1.0 / 3.0);
            p1 = mix(p1, p0, 1.0 / 3.0);
        }
    }

    return CubicPoints(p0, p1, p2, p3);
}

struct NeighboringSegment {
    do_join: bool,
    p0: vec2f,

    // Device-space start tangent vector
    tangent: vec2f,
}

fn read_neighboring_segment(ix: u32) -> NeighboringSegment {
    let tag = compute_tag_monoid(ix);
    let transform = read_transform(config.transform_base, tag.monoid.trans_ix);
    let pts = read_path_segment(tag, transform, true);

    let is_closed = (tag.tag_byte & PATH_TAG_SEG_TYPE) == PATH_TAG_LINETO;
    let is_stroke_cap_marker = (tag.tag_byte & PATH_TAG_SUBPATH_END) != 0u;
    let do_join = !is_stroke_cap_marker || is_closed;
    let p0 = pts.p0;
    let tangent = cubic_start_tangent(pts.p0, pts.p1, pts.p2, pts.p3);
    return NeighboringSegment(do_join, p0, tangent);
}

@compute @workgroup_size(256)
fn main(
    @builtin(global_invocation_id) global_id: vec3<u32>,
    @builtin(local_invocation_id) local_id: vec3<u32>,
) {
    let ix = global_id.x;
    pathdata_base = config.pathdata_base;

    let tag = compute_tag_monoid(ix);
    let path_ix = tag.monoid.path_ix;
    let style_ix = tag.monoid.style_ix;
    let trans_ix = tag.monoid.trans_ix;

    let out = &path_bboxes[path_ix];
    let style_flags = scene[config.style_base + style_ix];
    // The fill bit is always set to 0 for strokes which represents a non-zero fill.
    let draw_flags = select(DRAW_INFO_FLAGS_FILL_RULE_BIT, 0u, (style_flags & STYLE_FLAGS_FILL) == 0u);
    if (tag.tag_byte & PATH_TAG_PATH) != 0u {
        (*out).draw_flags = draw_flags;
        (*out).trans_ix = trans_ix;
    }
    // Decode path data
    let seg_type = tag.tag_byte & PATH_TAG_SEG_TYPE;
    if seg_type != 0u {
        let is_stroke = (style_flags & STYLE_FLAGS_STYLE) != 0u;
        let transform = read_transform(config.transform_base, trans_ix);
        let pts = read_path_segment(tag, transform, is_stroke);
        var bbox = vec4(min(pts.p0, pts.p1), max(pts.p0, pts.p1));
        bbox = vec4(min(bbox.xy, pts.p2), max(bbox.zw, pts.p2));
        bbox = vec4(min(bbox.xy, pts.p3), max(bbox.zw, pts.p3));

        var stroke = vec2(0.0, 0.0);
        if is_stroke {
            let linewidth = bitcast<f32>(scene[config.style_base + style_ix + 1u]);
            // See https://www.iquilezles.org/www/articles/ellipses/ellipses.htm
            // This is the correct bounding box, but we're not handling rendering
            // in the isotropic case, so it may mismatch.
            stroke = 0.5 * linewidth * vec2(length(transform.mat.xz), length(transform.mat.yw));
            bbox += vec4(-stroke, stroke);
            let is_open = (tag.tag_byte & PATH_TAG_SEG_TYPE) != PATH_TAG_LINETO;
            let is_stroke_cap_marker = (tag.tag_byte & PATH_TAG_SUBPATH_END) != 0u;
            if is_stroke_cap_marker {
                if is_open {
                    let n = cubic_start_normal(pts.p0, pts.p1, pts.p2, pts.p3) * stroke;

                    // Draw start cap
                    let line_ix = atomicAdd(&bump.lines, 1u);
                    lines[line_ix] = LineSoup(path_ix, pts.p0 - n, pts.p0 + n);
                } else {
                    // Don't draw anything if the path is closed.
                }
                // The stroke cap marker does not contribute to the path's bounding box. The stroke
                // width is accounted for when computing the bbox for regular segments.
                bbox = vec4(1., 1., -1., -1.);
            } else {
                // Render offset curves
                flatten_cubic(Cubic(pts.p0, pts.p1, pts.p2, pts.p3, stroke, path_ix, u32(is_stroke)));

                // Read the neighboring segment.
                let neighbor = read_neighboring_segment(ix + 1u);
                let n = normalize(cubic_end_normal(pts.p0, pts.p1, pts.p2, pts.p3)) * stroke;
                if neighbor.do_join {
                    // Draw join.
                    let nn = normalize(vec2(-neighbor.tangent.y, neighbor.tangent.x)) * stroke;
                    let line_ix = atomicAdd(&bump.lines, 2u);
                    lines[line_ix]      = LineSoup(path_ix, pts.p3 + n, neighbor.p0 + nn);
                    lines[line_ix + 1u] = LineSoup(path_ix, neighbor.p0 - nn, pts.p3 - n);
                } else {
                    // Draw end cap.
                    let line_ix = atomicAdd(&bump.lines, 1u);
                    lines[line_ix] = LineSoup(path_ix, pts.p3 + n, pts.p3 - n);
                }
            }
        } else {
            flatten_cubic(Cubic(pts.p0, pts.p1, pts.p2, pts.p3, stroke, path_ix, u32(is_stroke)));
        }
        // Update bounding box using atomics only. Computing a monoid is a
        // potential future optimization.
        if bbox.z > bbox.x || bbox.w > bbox.y {
            atomicMin(&(*out).x0, round_down(bbox.x));
            atomicMin(&(*out).y0, round_down(bbox.y));
            atomicMax(&(*out).x1, round_up(bbox.z));
            atomicMax(&(*out).y1, round_up(bbox.w));
        }
    }
}