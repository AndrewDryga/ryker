// The repository picker on Repositories: a search over the rows, Select all
// shown and Select none for the rows the search shows, and a live count on
// the button that adds the selection. Nothing starts ticked: 37 ticked rows
// meant unticking 32 to choose 5 (Andrew, 2026-09-26).

const checkbox = row => row.querySelector("input[type=checkbox]")
const choosable = row => {
  const box = checkbox(row)
  return box && !box.disabled
}

export const createRepositoryPicker = form => {
  const rows = () => [...form.querySelectorAll("[data-repository-name]")]
  // The choice lives here, not only in the checkboxes: a LiveView patch
  // redraws the rows from the server, which ticks nothing.
  const chosen = new Set()

  const remember = () => {
    rows().forEach(row => {
      if (!choosable(row)) return
      const box = checkbox(row)
      if (box.checked) chosen.add(box.value)
      else chosen.delete(box.value)
    })
  }

  const restore = () => {
    rows().forEach(row => {
      if (choosable(row)) checkbox(row).checked = chosen.has(checkbox(row).value)
    })
  }

  const count = () => {
    const selected = rows().filter(row => choosable(row) && checkbox(row).checked).length
    const button = form.querySelector("[data-repository-add-selected]")
    if (!button) return
    button.textContent = `Add ${selected} selected`
    button.disabled = selected === 0
  }

  const filter = () => {
    const search = form.querySelector("[data-repository-search]")
    const query = search ? search.value.trim().toLowerCase() : ""
    rows().forEach(row => {
      row.hidden = query !== "" && !row.dataset.repositoryName.toLowerCase().includes(query)
    })
  }

  const select = value => {
    rows().forEach(row => {
      if (!row.hidden && choosable(row)) checkbox(row).checked = value
    })
    remember()
    count()
  }

  const onInput = event => {
    if (event.target.matches("[data-repository-search]")) filter()
  }

  const onChange = event => {
    if (!event.target.matches("input[type=checkbox]")) return
    remember()
    count()
  }

  const onClick = event => {
    const control = event.target.closest && event.target.closest("[data-repository-select]")
    if (!control) return
    event.preventDefault()
    select(control.dataset.repositorySelect === "all")
  }

  return {
    mounted() {
      form.addEventListener("input", onInput)
      form.addEventListener("change", onChange)
      form.addEventListener("click", onClick)
      remember()
      filter()
      count()
    },
    updated() {
      restore()
      filter()
      count()
    },
    destroyed() {
      form.removeEventListener("input", onInput)
      form.removeEventListener("change", onChange)
      form.removeEventListener("click", onClick)
    }
  }
}

export const RepositoryPicker = {
  mounted() {
    this.picker = createRepositoryPicker(this.el)
    this.picker.mounted()
  },
  updated() { this.picker.updated() },
  destroyed() { this.picker.destroyed() }
}
