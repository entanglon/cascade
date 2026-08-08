//
//  Metaball.metal
//  xCloud
//
//  Fallback / more-controllable renderer for the FAB metaball. Two circle
//  signed-distance-fields are combined with a polynomial smooth-min, giving
//  an analytically anti-aliased silhouette with no blur convolution and no
//  binary alphaThreshold step. Generalizes cleanly to N blobs later (e.g.
//  multiple simultaneous transfer indicators) by chaining smin calls.
//

#include <metal_stdlib>
using namespace metal;

inline float sdCircle(float2 p, float2 center, float radius) {
    return length(p - center) - radius;
}

// Polynomial smooth minimum (Inigo Quilez). k controls neck softness:
// larger k = wider, gooier bridge; k -> 0 approaches a hard union with no
// visible neck at all.
inline float smin(float a, float b, float k) {
    float h = clamp(0.5 + 0.5 * (b - a) / k, 0.0, 1.0);
    return mix(b, a, h) - k * h * (1.0 - h);
}

/// Masks `color`'s alpha to the union of two soft-blended circles, with an
/// anti-aliased edge. Apply this directly on top of a glass layer (e.g.
/// .ultraThinMaterial) as a colorEffect — no separate mask view needed.
///
/// - addCenter / addRadius: the Add button blob.
/// - transferCenter / transferRadius: the Transfers button blob. Radius 0
///   correctly degenerates to "just the Add button, un-pinched" since the
///   smin branch is skipped entirely below that threshold.
/// - neckSoftness: the smooth-min `k`, in points. ~18-28pt reads as a
///   convincing liquid neck at typical FAB sizes (48-56pt circles);
///   tune to taste against your actual sizes.
/// - edgeSoftness: width, in points, of the anti-aliasing ramp at the
///   silhouette edge. ~1.0-1.5pt kills jaggies without reading as blurry.
[[ stitchable ]]
half4 metaballMask(
    float2 position,
    half4  color,
    float2 addCenter,
    float  addRadius,
    float2 transferCenter,
    float  transferRadius,
    float  neckSoftness,
    float  edgeSoftness
) {
    float dAdd = sdCircle(position, addCenter, addRadius);

    float d;
    if (transferRadius <= 0.001) {
        d = dAdd;
    } else {
        float dTransfer = sdCircle(position, transferCenter, transferRadius);
        d = smin(dAdd, dTransfer, neckSoftness);
    }

    float alpha = 1.0 - smoothstep(-edgeSoftness, edgeSoftness, d);
    return half4(color.rgb, color.a * half(alpha));
}
