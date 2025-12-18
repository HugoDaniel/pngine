
const BPM = 170.0;
const BEAT_SECS = BPM * f32(0.016666666666666666); // 1/60
// Returns 0.0 if beat < start
// Returns 1.0 if beat > end
// Returns 0.0->1.0 in between
fn progress(beat: f32, start: f32, end: f32) -> f32 {
    return clamp((beat - start) / (end - start), 0.0, 1.0);
}

fn easing(v: vec4f, end: f32, t: f32) -> f32 {
    let start = v.x;
    let easingId = u32(v.y + 0.5); // Round to nearest int
    
    // Parameters extracted for clarity
    let p1 = v.z; 
    let p2 = v.w;

    var factor = t; // Default: Linear

    switch easingId {
        case 1u: {
            // ID 1: Linear with Sine offset
            // p1 = Frequency (Speed of oscillation)
            // p2 = Amplitude (Size of the wave)
            // Useful for: Shaking effects, wobbling intensity, or electrical flickering.
            // Note: Does not guarantee landing exactly at 1.0 if t=1.0, unless p2 is 0.
            factor = t + (sin(t * p1) * p2);
        }
        case 2u: {
            // ID 2: Smoothstep
            // Standard smooth start and end. 
            // Params ignored.
            factor = smoothstep(0.0, 1.0, t);
        }
        default: {
            // Fallback: Linear
            factor = t;
        }
    }

    return mix(start, end, factor);
}

// sin, smoothstep, easing param1, easing param2) 
// vec4(v, id easing )
fn bar4(beat: f32, b1: vec4f, b2: vec4f, b3: vec4f, b4: vec4f) -> f32 {
    // 1. Determine where we are in the 4-beat cycle (0.0 to 3.999...)
    let barPosition = beat % 4.0;
    
    // 2. Identify the specific beat index (0, 1, 2, or 3)
    let beatIndex = u32(barPosition);
    
    // 3. Extract local time 't' for the current beat (0.0 to 1.0)
    let t = fract(barPosition);

    var currentConfig: vec4f;
    var nextTarget: f32;

    switch beatIndex {
        case 0u: {
            // Beat 1: Animate from b1 to b2
            currentConfig = b1;
            nextTarget = b2.x; // The start value of the next beat is our target
        }
        case 1u: {
            // Beat 2: Animate from b2 to b3
            currentConfig = b2;
            nextTarget = b3.x;
        }
        case 2u: {
            // Beat 3: Animate from b3 to b4
            currentConfig = b3;
            nextTarget = b4.x;
        }
        case 3u: {
            // Beat 4: Animate from b4 back to b1 (Looping)
            currentConfig = b4;
            nextTarget = b1.x; // Closing the loop
        }
        default: {
            // Fallback
            currentConfig = b1;
            nextTarget = b1.x;
        }
    }

    // Delegate the actual math to our previously defined easing function
    return easing(currentConfig, nextTarget, t);
}

