// While a preview is open, an extra (same-address) history entry makes the browser's
// Back button (or a phone's back gesture) close the preview instead of moving the
// folder view behind it, the way photo viewers on phones behave. Closing the preview
// any other way removes the entry again, so Back/Forward then work as before.

const STATE_KEY = 'myfilesPreview'
let onBack = null // close function of the open preview, if any

window.addEventListener('popstate', (e) => {
  if (onBack) {
    const close = onBack
    onBack = null
    close()
  } else if (e.state?.[STATE_KEY]) {
    // Forward onto the entry of a preview that has since closed: step back over it,
    // so Forward never lands on a "nothing happens" step.
    history.back()
  }
})

export function previewOpened(close) {
  onBack = close
  history.pushState({ [STATE_KEY]: true }, '')
}

export function previewClosed() {
  if (!onBack) return // already closed by Back
  onBack = null
  if (history.state?.[STATE_KEY]) history.back()
}
