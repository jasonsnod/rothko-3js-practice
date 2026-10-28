// Counts how long the painting has been on view, across visits.
//
// The count is saved in the browser's localStorage, so fading resumes exactly
// where it left off. It only advances while the page is being rendered (the
// animation loop pauses in hidden tabs), so it measures viewing time, not
// wall-clock time.
//
// Storage can be unavailable (private windows, blocked site data), so every
// access is guarded. Without it, fading simply starts fresh on each visit.

const STORAGE_KEY = 'rothko-practice:fade-seconds';
const SAVE_EVERY_SECONDS = 5;

export class FadeClock {
  constructor() {
    this.seconds = load();
    this.lastSaved = this.seconds;

    // Save when the page is hidden or closed, so at most a few seconds of
    // viewing time are lost if the browser quits abruptly.
    const saveNow = () => this.save();
    document.addEventListener('visibilitychange', () => {
      if (document.visibilityState === 'hidden') saveNow();
    });
    window.addEventListener('pagehide', saveNow);
  }

  advance(deltaSeconds) {
    this.seconds += deltaSeconds;
    if (Math.abs(this.seconds - this.lastSaved) >= SAVE_EVERY_SECONDS) this.save();
  }

  set(seconds) {
    this.seconds = Math.max(0, seconds);
    this.save();
  }

  save() {
    try {
      localStorage.setItem(STORAGE_KEY, String(this.seconds));
      this.lastSaved = this.seconds;
    } catch {
      // Storage unavailable: progress lasts only for this visit.
    }
  }
}

function load() {
  try {
    const value = Number(localStorage.getItem(STORAGE_KEY));
    return Number.isFinite(value) && value > 0 ? value : 0;
  } catch {
    return 0;
  }
}
