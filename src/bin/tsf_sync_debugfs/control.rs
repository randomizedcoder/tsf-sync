/// 1D Kalman filter for smoothing the TSF error signal.
pub struct KalmanFilter1D {
    x: f64, // state estimate
    p: f64, // estimate covariance
    q: f64, // process noise
    r: f64, // measurement noise
}

impl KalmanFilter1D {
    pub fn new() -> Self {
        Self {
            x: 0.0,
            p: 1.0,
            q: 50.0,
            r: 4000.0,
        }
    }

    /// Update with a new measurement, return the filtered estimate.
    pub fn update(&mut self, z: f64) -> f64 {
        // Predict
        self.p += self.q;
        // Update
        let k = self.p / (self.p + self.r);
        self.x += k * (z - self.x);
        self.p *= 1.0 - k;
        self.x
    }
}

/// Proportional controller matching FiWiTSF's algorithm.
pub struct Controller {
    kp_ppm: i64,
    max_step_us: i64,
    kalman: Option<KalmanFilter1D>,
}

impl Controller {
    pub fn new(kp_ppm: i64, max_step_us: i64, use_kalman: bool) -> Self {
        Self {
            kp_ppm,
            max_step_us,
            kalman: if use_kalman {
                Some(KalmanFilter1D::new())
            } else {
                None
            },
        }
    }

    /// Compute the correction step for a follower.
    ///
    /// Returns `(step_us, raw_err)` where:
    /// - `raw_err = master_tsf - follower_tsf` (signed, microseconds)
    /// - `step_us` is the clamped proportional correction to add to the follower TSF
    pub fn apply(&mut self, master_tsf: u64, follower_tsf: u64) -> (i64, i64) {
        let raw_err = master_tsf as i64 - follower_tsf as i64;

        let err = match self.kalman {
            Some(ref mut kf) => kf.update(raw_err as f64) as i64,
            None => raw_err,
        };

        let step = clamp_step((err * self.kp_ppm) / 1_000_000, self.max_step_us, err);
        (step, raw_err)
    }
}

/// Clamp a proportional step to ±max_step_us.
/// If the step rounds to zero but error is nonzero, force ±1µs minimum.
#[inline(always)]
fn clamp_step(step: i64, max_step_us: i64, err: i64) -> i64 {
    let clamped = step.clamp(-max_step_us, max_step_us);
    if clamped == 0 && err != 0 {
        if err > 0 {
            1
        } else {
            -1
        }
    } else {
        clamped
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    // ── clamp_step unit tests ──

    #[test]
    fn clamp_within_range() {
        assert_eq!(clamp_step(100, 200, 100), 100);
    }

    #[test]
    fn clamp_positive_max() {
        assert_eq!(clamp_step(500, 200, 500), 200);
    }

    #[test]
    fn clamp_negative_max() {
        assert_eq!(clamp_step(-500, 200, -500), -200);
    }

    #[test]
    fn clamp_minimum_positive() {
        assert_eq!(clamp_step(0, 200, 10), 1);
    }

    #[test]
    fn clamp_minimum_negative() {
        assert_eq!(clamp_step(0, 200, -10), -1);
    }

    #[test]
    fn clamp_zero_error_zero_step() {
        assert_eq!(clamp_step(0, 200, 0), 0);
    }

    // ── Controller integration tests ──

    #[test]
    fn proportional_basic() {
        let mut ctrl = Controller::new(1_000_000, 200, false);
        let (step, err) = ctrl.apply(1_000_100, 1_000_000);
        assert_eq!(err, 100);
        assert_eq!(step, 100);
    }

    #[test]
    fn proportional_clamped() {
        let mut ctrl = Controller::new(1_000_000, 200, false);
        let (step, err) = ctrl.apply(1_000_500, 1_000_000);
        assert_eq!(err, 500);
        assert_eq!(step, 200);
    }

    #[test]
    fn proportional_negative() {
        let mut ctrl = Controller::new(1_000_000, 200, false);
        let (step, err) = ctrl.apply(1_000_000, 1_000_050);
        assert_eq!(err, -50);
        assert_eq!(step, -50);
    }

    #[test]
    fn minimum_step() {
        let mut ctrl = Controller::new(1, 200, false);
        let (step, err) = ctrl.apply(1_000_010, 1_000_000);
        assert_eq!(err, 10);
        assert_eq!(step, 1);
    }

    #[test]
    fn zero_error() {
        let mut ctrl = Controller::new(1_000_000, 200, false);
        let (step, err) = ctrl.apply(1_000_000, 1_000_000);
        assert_eq!(err, 0);
        assert_eq!(step, 0);
    }

    #[test]
    fn kalman_smoothing() {
        let mut ctrl = Controller::new(1_000_000, 200, true);
        let (step1, _) = ctrl.apply(1_000_100, 1_000_000);
        assert!(step1 < 100);
        assert!(step1 > 0);
    }
}
