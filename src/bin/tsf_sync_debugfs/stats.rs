/// Welford online statistics accumulator.
pub struct WelfordStats {
    n: u64,
    mean: f64,
    m2: f64,
    max_abs_err: i64,
    max_abs_step: i64,
}

impl WelfordStats {
    pub fn new() -> Self {
        Self {
            n: 0,
            mean: 0.0,
            m2: 0.0,
            max_abs_err: 0,
            max_abs_step: 0,
        }
    }

    /// Accumulate one error + step observation.
    pub fn update(&mut self, err: i64, step: i64) {
        self.n += 1;
        let x = err as f64;
        let delta = x - self.mean;
        self.mean += delta / self.n as f64;
        let delta2 = x - self.mean;
        self.m2 += delta * delta2;

        let abs_err = err.unsigned_abs() as i64;
        if abs_err > self.max_abs_err {
            self.max_abs_err = abs_err;
        }
        let abs_step = step.unsigned_abs() as i64;
        if abs_step > self.max_abs_step {
            self.max_abs_step = abs_step;
        }
    }

    /// Root mean square of the error.
    pub fn rms(&self) -> f64 {
        if self.n == 0 {
            return 0.0;
        }
        (self.m2 / self.n as f64).sqrt()
    }

    /// Print stats and reset accumulators. Returns the RMS value.
    pub fn print_and_reset(&mut self, label: &str) -> f64 {
        let rms = self.rms();
        if self.n > 0 {
            eprintln!(
                "[{label}] n={} mean={:.1}µs rms={:.1}µs max_err={}µs max_step={}µs",
                self.n, self.mean, rms, self.max_abs_err, self.max_abs_step,
            );
        }
        *self = Self::new();
        rms
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn empty_stats() {
        let s = WelfordStats::new();
        assert_eq!(s.rms(), 0.0);
    }

    #[test]
    fn single_sample() {
        let mut s = WelfordStats::new();
        s.update(10, 5);
        assert_eq!(s.n, 1);
        assert!((s.mean - 10.0).abs() < f64::EPSILON);
        assert_eq!(s.max_abs_err, 10);
        assert_eq!(s.max_abs_step, 5);
    }

    #[test]
    fn welford_accuracy() {
        let mut s = WelfordStats::new();
        // Known: 3 samples [2, 4, 6]. mean=4, variance=8/3, rms=sqrt(8/3)
        s.update(2, 1);
        s.update(4, 2);
        s.update(6, 3);
        assert!((s.mean - 4.0).abs() < 1e-10);
        let expected_rms = (8.0_f64 / 3.0).sqrt();
        assert!((s.rms() - expected_rms).abs() < 1e-10);
    }

    #[test]
    fn negative_errors() {
        let mut s = WelfordStats::new();
        s.update(-100, -50);
        assert_eq!(s.max_abs_err, 100);
        assert_eq!(s.max_abs_step, 50);
    }

    #[test]
    fn print_resets() {
        let mut s = WelfordStats::new();
        s.update(10, 5);
        s.update(20, 10);
        let rms = s.print_and_reset("test");
        assert!(rms > 0.0);
        assert_eq!(s.n, 0);
    }
}
