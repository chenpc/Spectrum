// SPDX-License-Identifier: GPL-3.0-or-later
// gyrocore_c: C-compatible API for gyroflow-core matrix computation.
//
// Compiled as cdylib → libgyrocore_c.dylib
// Loaded by testmpv at runtime via dlopen (same pattern as libmpv).
//
// API:
//   gyrocore_load(path, lens_path, config_json) → opaque handle (NULL on failure)
//   gyrocore_get_params(handle, buf40)      → 0 on success
//   gyrocore_get_frame(handle, frame_idx, float_buf) → row_count*9 or -1
//   gyrocore_free(handle)
//
// gyrocore_get_params output layout (40 bytes, little-endian):
//   [0..4]   frame_count (u32)
//   [4..8]   row_count   (u32)   – per-frame matrix rows (= vid_h when RS)
//   [8..12]  video_w     (u32)
//   [12..16] video_h     (u32)
//   [16..24] fps         (f64)
//   [24..28] fx          (f32)   – focal length x in pixels
//   [28..32] fy          (f32)
//   [32..36] cx          (f32)   – principal point x
//   [36..40] cy          (f32)
//
// gyrocore_get_frame output: row_count × 9 × f32 (3×3 matrix per row, row-major)
//
// Shader pipeline (gyroflow convention):
//   (_x,_y,_w) = mat3 × (out_px.x, out_px.y, 1)
//   src_x      = fx × (_x/_w) + cx
//   src_y      = fy × (_y/_w) + cy

use gyroflow_core::{StabilizationManager, timestamp_at_frame};
use gyroflow_core::stabilization::{ComputeParams, FrameTransform};
use std::ffi::CStr;
use std::io::Write as _;
use std::os::raw::{c_char, c_int};
use serde::{Deserialize};
use serde_json::Value as JVal;

/// JSON-configurable parameters for gyrocore_load.
/// All fields are optional — omit or pass null config_json to use defaults.
#[derive(Debug, Deserialize)]
#[serde(default)]
struct Config {
    readout_ms:             f64,     // Rolling shutter readout time (0 = skip RS correction)
    smooth:                 f64,     // Global smoothness 0.001–1.0 (0 = default 0.5)
    gyro_offset_ms:         f64,     // Gyro-video sync offset in ms
    integration_method:     i32,     // 0=Complementary 1=Complementary2 2=VQF
    imu_orientation:        String,  // e.g. "YXz"
    fov:                    f64,     // FOV scale (1.0 = nominal)
    lens_correction_amount: f64,     // 0.0–1.0 (1.0 = full correction)
    zooming_method:         i32,     // 0=None 1=EnvelopeFollower
    adaptive_zoom:          f64,     // Adaptive zoom window in seconds
    max_zoom:               f64,     // Max zoom percentage
    max_zoom_iterations:    i32,     // Iterations for max zoom computation
    use_gravity_vectors:    bool,    // Use accelerometer gravity for horizon
    video_speed:            f64,     // Playback speed (1.0 = normal)
    horizon_lock_amount:    f64,     // 0.0–1.0 horizon lock strength
    horizon_lock_roll:      f64,     // Additional roll correction in degrees
    per_axis:               bool,    // Enable per-axis smoothing
    smoothness_pitch:       f64,     // Per-axis pitch smoothness (0 = use global)
    smoothness_yaw:         f64,     // Per-axis yaw smoothness (0 = use global)
    smoothness_roll:        f64,     // Per-axis roll smoothness (0 = use global)
}

impl Default for Config {
    fn default() -> Self {
        Self {
            readout_ms:             0.0,
            smooth:                 0.0,    // 0 → will be treated as 0.5
            gyro_offset_ms:         0.0,
            integration_method:     2,      // VQF
            imu_orientation:        "YXz".into(),
            fov:                    1.0,
            lens_correction_amount: 1.0,
            zooming_method:         1,      // EnvelopeFollower
            adaptive_zoom:          4.0,    // seconds
            max_zoom:               130.0,  // percent
            max_zoom_iterations:    5,
            use_gravity_vectors:    false,
            video_speed:            1.0,
            horizon_lock_amount:    0.0,
            horizon_lock_roll:      0.0,
            per_axis:               false,
            smoothness_pitch:       0.0,    // 0 = use global
            smoothness_yaw:         0.0,
            smoothness_roll:        0.0,
        }
    }
}

struct State {
    frame_count:    usize,
    row_count:      usize,
    scaled_fps:     f64,
    vid_w:          usize,
    vid_h:          usize,
    fps:            f64,
    fx: f32, fy: f32,
    cx: f32, cy: f32,
    compute_params: ComputeParams,
}

// ─── Load ─────────────────────────────────────────────────────────────────────

/// Load a video file, configure gyroflow stabilization, and run recompute_blocking().
/// Blocks ~0.3 s. Returns an opaque handle on success, NULL on failure.
/// Progress/errors are printed to stderr.
///
/// video_path:  Path to the video file containing embedded gyro data.
/// lens_path:   Nullable path to a .gyroflow project file (or standalone lens JSON).
///              When provided, extracts calibration_data and offsets.
/// config_json: Nullable JSON string with Config fields. Omitted fields use defaults.
///              Pass NULL to use all defaults.
#[unsafe(no_mangle)]
pub extern "C" fn gyrocore_load(
    video_path:  *const c_char,
    lens_path:   *const c_char,  // nullable; .gyroflow or lens profile JSON
    config_json: *const c_char,  // nullable; JSON Config string
) -> *mut State {
    let res = std::panic::catch_unwind(|| -> Result<*mut State, Box<dyn std::error::Error>> {
        let path_str = unsafe { CStr::from_ptr(video_path) }.to_str()?;

        // Parse config from JSON or use defaults
        let cfg: Config = if !config_json.is_null() {
            let json_str = unsafe { CStr::from_ptr(config_json) }.to_str()?;
            serde_json::from_str(json_str).unwrap_or_else(|e| {
                eprintln!("[gyrocore] ⚠️  Config parse error: {e}, using defaults");
                Config::default()
            })
        } else {
            Config::default()
        };
        let eff_smooth = if cfg.smooth > 0.0 { cfg.smooth } else { 0.5 };
        eprintln!("[gyrocore] Config: {:?}", cfg);

        let canonical = std::fs::canonicalize(path_str)?;
        let url       = format!("file://{}", canonical.display());
        let mut file  = std::fs::File::open(&canonical)?;
        let file_size = file.metadata()?.len() as usize;

        eprintln!("[gyrocore] Loading: {}", canonical.display());
        let stab = StabilizationManager::default();
        stab.load_video_file(&mut file, file_size, &url, None, false)
            .map_err(|e| format!("load_video_file: {e:?}"))?;

        let (vid_w, vid_h, fps, frame_count) = {
            let p = stab.params.read();
            (p.size.0, p.size.1, p.fps, p.frame_count)
        };
        if frame_count == 0 || fps == 0.0 {
            return Err(format!("No gyro data (frame_count={frame_count}, fps={fps})").into());
        }
        eprintln!("[gyrocore] {}×{} @ {:.3} fps, {} frames", vid_w, vid_h, fps, frame_count);

        // ── Motion data diagnostics ────────────────────────────────────────
        {
            let gyro = stab.gyro.read();
            let md = gyro.file_metadata.read();
            let raw_count = md.raw_imu.len();
            let quat_count = md.quaternions.len();
            let has_motion = md.has_motion();
            let source = md.detected_source.as_deref().unwrap_or("unknown");
            let orientation = md.imu_orientation.as_deref().unwrap_or("none");
            let readout = md.frame_readout_time;
            eprintln!("[gyrocore] ── Motion Data ──────────────────────────────");
            eprintln!("[gyrocore]   source       : {}", source);
            eprintln!("[gyrocore]   has_motion   : {}  raw_imu: {}  quaternions: {}", has_motion, raw_count, quat_count);
            eprintln!("[gyrocore]   orientation  : {}", orientation);
            eprintln!("[gyrocore]   readout_time : {:?}", readout);
            if raw_count > 0 {
                // Print first & last few IMU samples
                let first = &md.raw_imu[0];
                let last  = &md.raw_imu[raw_count - 1];
                eprintln!("[gyrocore]   imu[0]       : t={:.3}ms gyro={:?} accl={:?}", first.timestamp_ms, first.gyro, first.accl);
                if raw_count > 1 {
                    let s1 = &md.raw_imu[1];
                    let dt = s1.timestamp_ms - first.timestamp_ms;
                    let sample_rate = if dt > 0.0 { 1000.0 / dt } else { 0.0 };
                    eprintln!("[gyrocore]   imu[1]       : t={:.3}ms  (dt={:.3}ms → ~{:.0} Hz)", s1.timestamp_ms, dt, sample_rate);
                }
                eprintln!("[gyrocore]   imu[{}]  : t={:.3}ms gyro={:?}", raw_count-1, last.timestamp_ms, last.gyro);
                // Check for non-zero gyro values
                let nonzero_count = md.raw_imu.iter()
                    .filter(|d| d.gyro.map_or(false, |g| g[0].abs() > 1e-6 || g[1].abs() > 1e-6 || g[2].abs() > 1e-6))
                    .count();
                eprintln!("[gyrocore]   non-zero gyro: {}/{} ({:.1}%)", nonzero_count, raw_count, 100.0 * nonzero_count as f64 / raw_count as f64);
                // Max angular velocity
                let max_gyro = md.raw_imu.iter()
                    .filter_map(|d| d.gyro)
                    .fold(0.0_f64, |mx, g| mx.max(g[0].abs()).max(g[1].abs()).max(g[2].abs()));
                eprintln!("[gyrocore]   max |gyro|   : {:.4} rad/s ({:.2} deg/s)", max_gyro, max_gyro.to_degrees());
            }
            eprintln!("[gyrocore] ──────────────────────────────────────────────");
        }

        // ── Lens profile + .gyroflow project ────────────────────────────────
        // Check if load_video_file auto-detected a lens profile from the camera DB
        let auto_loaded = stab.lens.read().fisheye_params.camera_matrix.len() == 3;
        let mut project_offsets: Option<std::collections::BTreeMap<i64, f64>> = None;

        if auto_loaded {
            let l = stab.lens.read();
            eprintln!("[gyrocore] ✅ Lens auto-detected: {} {} {}", l.camera_brand, l.camera_model, l.lens_model);
        }

        // Load .gyroflow project file: extract lens calibration + sync offsets
        if !lens_path.is_null() {
            let lpath = unsafe { CStr::from_ptr(lens_path) }.to_str()?;
            if let Ok(json) = std::fs::read_to_string(lpath) {
                if let Ok(v) = serde_json::from_str::<JVal>(&json) {
                    // Extract lens calibration_data (only if not auto-detected)
                    if !auto_loaded {
                        let calib_str = if let Some(calib) = v.get("calibration_data") {
                            serde_json::to_string(calib).ok()
                        } else {
                            Some(json.clone())
                        };
                        if let Some(cs) = calib_str {
                            match stab.load_lens_profile(&cs) {
                                Ok(_) => {
                                    let l = stab.lens.read();
                                    eprintln!("[gyrocore] ✅ Lens loaded from {}: {} {} {}",
                                              std::path::Path::new(lpath).file_name().unwrap_or_default().to_string_lossy(),
                                              l.camera_brand, l.camera_model, l.lens_model);
                                }
                                Err(e) => eprintln!("[gyrocore] ⚠️  Lens profile load failed: {e:?}"),
                            }
                        }
                    }
                    // Extract sync offsets: { "timestamp_us": offset_ms, ... }
                    if let Some(JVal::Object(offsets)) = v.get("offsets") {
                        let map: std::collections::BTreeMap<i64, f64> = offsets.iter()
                            .filter_map(|(k, v)| Some((k.parse().ok()?, v.as_f64()?)))
                            .collect();
                        if !map.is_empty() {
                            eprintln!("[gyrocore] ✅ Loaded {} sync offsets from project file", map.len());
                            project_offsets = Some(map);
                        }
                    }
                }
            }
        }

        if !auto_loaded && project_offsets.is_none() && lens_path.is_null() {
            eprintln!("[gyrocore] ⚠️  No lens profile (fallback: fx=w×0.8). Pass lens_path for accuracy.");
        }

        stab.set_size(vid_w, vid_h);
        stab.set_output_size(vid_w, vid_h);
        stab.set_device(-1);

        // ── Gyro-video sync offset ─────────────────────────────────────────
        if let Some(offsets) = &project_offsets {
            // Apply per-timestamp offsets from .gyroflow project
            for (&ts, &off) in offsets {
                stab.set_offset(ts, off);
            }
            let avg: f64 = offsets.values().sum::<f64>() / offsets.len() as f64;
            eprintln!("[gyrocore]   sync offsets: {} points, avg={:.2}ms", offsets.len(), avg);
        } else if cfg.gyro_offset_ms.abs() > 0.001 {
            // Apply single global offset
            stab.set_offset(0, cfg.gyro_offset_ms);
            eprintln!("[gyrocore]   gyro_offset  : {:.3} ms", cfg.gyro_offset_ms);
        }

        // ── IMU integration (must set BEFORE recompute_blocking) ────────────
        {
            let mut gyro = stab.gyro.write();
            gyro.integration_method = cfg.integration_method as usize;
        }
        stab.set_imu_orientation(cfg.imu_orientation.clone());

        // ── Smoothing (method: "Default" = 1) ────────────────────────────────
        stab.set_smoothing_method(1);
        if cfg.smooth > 0.0 {
            stab.set_smoothing_param("smoothness", cfg.smooth);
        }
        if cfg.per_axis {
            stab.set_smoothing_param("per_axis", 1.0);
            if cfg.smoothness_pitch > 0.0 { stab.set_smoothing_param("smoothness_pitch", cfg.smoothness_pitch); }
            if cfg.smoothness_yaw   > 0.0 { stab.set_smoothing_param("smoothness_yaw",   cfg.smoothness_yaw); }
            if cfg.smoothness_roll  > 0.0 { stab.set_smoothing_param("smoothness_roll",  cfg.smoothness_roll); }
        }

        // ── Stabilization ────────────────────────────────────────────────────
        stab.set_fov(cfg.fov);
        stab.set_stab_enabled(true);
        stab.set_lens_correction_amount(cfg.lens_correction_amount);
        stab.set_zooming_method(cfg.zooming_method);
        stab.set_adaptive_zoom(cfg.adaptive_zoom);
        stab.set_max_zoom(cfg.max_zoom, cfg.max_zoom_iterations as usize);
        stab.set_use_gravity_vectors(cfg.use_gravity_vectors);
        stab.set_video_speed(cfg.video_speed, true, true, true);

        // ── Horizon lock ────────────────────────────────────────────────────
        if cfg.horizon_lock_amount > 0.0 || cfg.horizon_lock_roll.abs() > 0.001 {
            stab.set_horizon_lock(cfg.horizon_lock_amount, cfg.horizon_lock_roll, false, 0.0);
        }

        // ── Rolling shutter ──────────────────────────────────────────────────
        // Prefer readout time embedded in video metadata; fall back to caller's value
        let eff_readout = {
            let md_readout = stab.gyro.read().file_metadata.read().frame_readout_time;
            if let Some(r) = md_readout { if r > 0.0 { r } else { cfg.readout_ms } } else { cfg.readout_ms }
        };
        if eff_readout > 0.0 {
            stab.set_frame_readout_time(eff_readout);
        }

        eprintln!("[gyrocore] ── Settings ──────────────────────────────────");
        eprintln!("[gyrocore]   integration: {} ({})  orientation: {}",
                  cfg.integration_method,
                  match cfg.integration_method { 0 => "Complementary", 1 => "Complementary2", 2 => "VQF", _ => "?" },
                  cfg.imu_orientation);
        eprintln!("[gyrocore]   method     : 1 (Default)  smoothness: {:.3}  per_axis: {}", eff_smooth, cfg.per_axis);
        if cfg.per_axis {
            eprintln!("[gyrocore]   pitch={:.3}  yaw={:.3}  roll={:.3}", cfg.smoothness_pitch, cfg.smoothness_yaw, cfg.smoothness_roll);
        }
        eprintln!("[gyrocore]   fov: {:.2}  lens_correction: {:.2}  zoom_method: {}  zoom_window: {:.1}s  max_zoom: {:.0}%",
                  cfg.fov, cfg.lens_correction_amount, cfg.zooming_method, cfg.adaptive_zoom, cfg.max_zoom);
        if cfg.horizon_lock_amount > 0.0 || cfg.horizon_lock_roll.abs() > 0.001 {
            eprintln!("[gyrocore]   horizon_lock: amount={:.2}  roll={:.1}°", cfg.horizon_lock_amount, cfg.horizon_lock_roll);
        }
        eprintln!("[gyrocore]   readout_ms : {:.3} (metadata: {:?}, arg: {:.3})  gyro_offset: {:.3} ms",
                  eff_readout, stab.gyro.read().file_metadata.read().frame_readout_time, cfg.readout_ms, cfg.gyro_offset_ms);
        eprintln!("[gyrocore] ─────────────────────────────────────────────");
        eprintln!("[gyrocore] Precomputing…");
        let t0 = std::time::Instant::now();
        stab.recompute_blocking();
        eprintln!("[gyrocore] Done in {:.1}s", t0.elapsed().as_secs_f64());

        // ── Post-recompute diagnostics ─────────────────────────────────────
        {
            let gyro = stab.gyro.read();
            let quat_count = gyro.quaternions.len();
            let smooth_count = gyro.smoothed_quaternions.len();
            let int_method = gyro.integration_method;
            let max_angles = gyro.max_angles;
            eprintln!("[gyrocore] ── After recompute ──────────────────────────");
            eprintln!("[gyrocore]   integration  : {} (0=Compl 1=Compl2 2=VQF)", int_method);
            eprintln!("[gyrocore]   quaternions  : {}  smoothed: {}", quat_count, smooth_count);
            eprintln!("[gyrocore]   max_angles   : pitch={:.1}° yaw={:.1}° roll={:.1}°", max_angles.0, max_angles.1, max_angles.2);
            // Sample a few quaternion differences (raw vs smoothed) to see smoothing effect
            if quat_count > 0 && smooth_count > 0 {
                let raw_keys: Vec<_> = gyro.quaternions.keys().collect();
                let n = raw_keys.len();
                for &idx in &[0, n/4, n/2, 3*n/4, n-1] {
                    if idx < n {
                        let ts = raw_keys[idx];
                        let raw_q = gyro.quaternions[ts];
                        if let Some((&_sk, &smooth_q)) = gyro.smoothed_quaternions.range(..=ts).next_back() {
                            let diff = raw_q.inverse() * smooth_q;
                            let angle_deg = diff.angle().to_degrees();
                            eprintln!("[gyrocore]   q[{:.1}s] raw→smooth diff: {:.3}°",
                                      *ts as f64 / 1_000_000.0, angle_deg);
                        }
                    }
                }
            }
            eprintln!("[gyrocore] ────────────────────────────────────────────");

            // ── IBIS/OIS diagnostics ─────────────────────────────────────
            let md = gyro.file_metadata.read();
            let stab_count = md.camera_stab_data.len();
            eprintln!("[gyrocore]   camera_stab_data: {} frames", stab_count);
            if stab_count > 0 {
                let is0 = &md.camera_stab_data[0];
                eprintln!("[gyrocore]   frame[0] sensor_size=({},{}), crop_area=({},{},{},{}), offset={:.1}",
                    is0.sensor_size.0, is0.sensor_size.1,
                    is0.crop_area.0, is0.crop_area.1, is0.crop_area.2, is0.crop_area.3,
                    is0.offset);
                // Sample IBIS data at y=0 for first frame
                if let Some(s) = is0.ibis_spline.interpolate(is0.offset) {
                    eprintln!("[gyrocore]   frame[0] ibis(y=0): sx={:.3} sy={:.3} ra={:.3}", s.x, s.y, s.z);
                } else {
                    eprintln!("[gyrocore]   frame[0] ibis(y=0): None");
                }
                if let Some(o) = is0.ois_spline.interpolate(is0.offset) {
                    eprintln!("[gyrocore]   frame[0] ois(y=0): ox={:.3} oy={:.3}", o.x, o.y);
                } else {
                    eprintln!("[gyrocore]   frame[0] ois(y=0): None");
                }
            }
        }

        let compute_params = ComputeParams::from_manager(&stab);
        let scaled_fps = {
            let p = stab.params.read();
            p.fps * p.fps_scale.unwrap_or(1.0)
        };

        let ts0 = timestamp_at_frame(0, scaled_fps);
        let ft0 = FrameTransform::at_timestamp(&compute_params, ts0, 0);
        let kp  = &ft0.kernel_params;

        let state = Box::new(State {
            frame_count,
            row_count: kp.matrix_count as usize,
            scaled_fps,
            vid_w, vid_h, fps,
            fx: kp.f[0], fy: kp.f[1],
            cx: kp.c[0], cy: kp.c[1],
            compute_params,
        });
        eprintln!("[gyrocore] f=[{:.2},{:.2}] c=[{:.2},{:.2}] rows={}",
                  state.fx, state.fy, state.cx, state.cy, state.row_count);

        Ok(Box::into_raw(state))
    });
    match res {
        Ok(Ok(ptr)) => ptr,
        Ok(Err(e))  => { eprintln!("[gyrocore] ❌ {e}"); std::ptr::null_mut() }
        Err(_)      => { eprintln!("[gyrocore] ❌ panic in gyrocore_load"); std::ptr::null_mut() }
    }
}

// ─── Get params ───────────────────────────────────────────────────────────────

/// Write 40-byte params blob into buf. Returns 0 on success, -1 on error.
/// Layout: frame_count(u32) row_count(u32) video_w(u32) video_h(u32)
///         fps(f64) fx(f32) fy(f32) cx(f32) cy(f32)  — all little-endian
#[unsafe(no_mangle)]
pub unsafe extern "C" fn gyrocore_get_params(
    handle: *const State,
    buf:    *mut u8,
) -> c_int {
    if handle.is_null() || buf.is_null() { return -1; }
    let s   = &*handle;
    let out = std::slice::from_raw_parts_mut(buf, 40);
    let mut w = std::io::Cursor::new(out);
    let _ = w.write_all(&(s.frame_count as u32).to_le_bytes());
    let _ = w.write_all(&(s.row_count   as u32).to_le_bytes());
    let _ = w.write_all(&(s.vid_w       as u32).to_le_bytes());
    let _ = w.write_all(&(s.vid_h       as u32).to_le_bytes());
    let _ = w.write_all(&s.fps.to_le_bytes());
    let _ = w.write_all(&s.fx.to_le_bytes());
    let _ = w.write_all(&s.fy.to_le_bytes());
    let _ = w.write_all(&s.cx.to_le_bytes());
    let _ = w.write_all(&s.cy.to_le_bytes());
    0
}

// ─── Get frame ────────────────────────────────────────────────────────────────

/// Compute matrices for frame_idx. output must hold ≥ row_count * 14 floats.
/// Each row: [mat3×3 (9 floats), sx, sy, ra (IBIS shift/rotation), ox, oy (OIS offset)]
/// Returns row_count * 14 on success, -1 on error.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn gyrocore_get_frame(
    handle:    *const State,
    frame_idx: u32,
    output:    *mut f32,
) -> c_int {
    if handle.is_null() || output.is_null() { return -1; }
    let s  = &*handle;
    let fi = (frame_idx as usize).min(s.frame_count.saturating_sub(1));

    let ts_ms   = timestamp_at_frame(fi as i32, s.scaled_fps);
    let ft      = FrameTransform::at_timestamp(&s.compute_params, ts_ms, fi);
    let mat_len = ft.matrices.len();
    let count   = s.row_count * 14;
    let out     = std::slice::from_raw_parts_mut(output, count);

    for row in 0..s.row_count {
        let m = if mat_len > 1 {
            ft.matrices.get(row).or_else(|| ft.matrices.last()).unwrap()
        } else {
            ft.matrices.first().unwrap_or(&[0.0_f32; 14])
        };
        let base = row * 14;
        out[base..base + 14].copy_from_slice(&m[..14]);
    }

    // One-time IBIS diagnostics: print scaled matrix values for frame 0
    static DIAG_DONE: std::sync::atomic::AtomicBool = std::sync::atomic::AtomicBool::new(false);
    if frame_idx == 0 && !DIAG_DONE.swap(true, std::sync::atomic::Ordering::Relaxed) {
        if let Some(m0) = ft.matrices.first() {
            eprintln!("[gyrocore] frame0 row0 IBIS(scaled): sx={:.3} sy={:.3} ra={:.6} ox={:.3} oy={:.3}",
                      m0[9], m0[10], m0[11], m0[12], m0[13]);
        }
        let mid = s.row_count / 2;
        if let Some(mm) = ft.matrices.get(mid) {
            eprintln!("[gyrocore] frame0 row{} IBIS(scaled): sx={:.3} sy={:.3} ra={:.6} ox={:.3} oy={:.3}",
                      mid, mm[9], mm[10], mm[11], mm[12], mm[13]);
        }
    }

    count as c_int
}

// ─── Free ─────────────────────────────────────────────────────────────────────

#[unsafe(no_mangle)]
pub unsafe extern "C" fn gyrocore_free(handle: *mut State) {
    if !handle.is_null() {
        drop(Box::from_raw(handle));
    }
}
