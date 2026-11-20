// A key is sent only on explicit submission and is never written to draft storage.
export const AccountField = {
  mounted() {
    this.field = this.el.querySelector("input:not([type=hidden])")
    this.success = this.el.dataset.success
    this.sync = () => {
      const changed = this.field.value.trim() !== this.el.dataset.saved
      this.el.querySelector("button[type=submit]").disabled = !changed || !this.field.validity.valid
    }
    this.el.addEventListener("input", this.sync)
    this.sync()
  },
  beforeUpdate() {
    this.draft = this.field.value !== this.el.dataset.saved ? this.field.value : null
  },
  updated() {
    this.field = this.el.querySelector("input:not([type=hidden])")
    if (this.el.dataset.success && this.el.dataset.success !== this.success) {
      this.field.value = this.el.dataset.saved
    } else if (this.draft !== null) {
      this.field.value = this.draft
    }
    this.draft = null
    this.success = this.el.dataset.success
    this.sync()
  },
  destroyed() { this.el.removeEventListener("input", this.sync) }
}
