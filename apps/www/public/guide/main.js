// ─────────────────────────────────────────────────────────────
// The Annotated Source — interactivity layer
// ─────────────────────────────────────────────────────────────

document.addEventListener('DOMContentLoaded', () => {
  initProgress()
  initToc()
  initSectionReveal()
  initCopyButtons()
  initXrefLinks()
})

// ── Reading Progress Bar ──────────────────────────────────

function initProgress() {
  const bar = document.getElementById('progress')
  if (!bar) return

  const update = () => {
    const scrollTop = window.scrollY
    const docHeight = document.documentElement.scrollHeight - window.innerHeight
    const pct = docHeight > 0 ? (scrollTop / docHeight) * 100 : 0
    bar.style.width = pct + '%'
  }

  window.addEventListener('scroll', update, { passive: true })
  update()
}

// ── Table of Contents ─────────────────────────────────────

function initToc() {
  const toc = document.getElementById('toc')
  if (!toc) return

  const sections = Array.from(document.querySelectorAll('section[id]'))
  const links = Array.from(toc.querySelectorAll('a[href^="#"]'))

  // Show TOC after scrolling past hero
  const hero = document.querySelector('.hero')
  if (hero) {
    const obs = new IntersectionObserver(
      ([entry]) => {
        toc.classList.toggle('visible', !entry.isIntersecting)
        document.body.classList.toggle('toc-open', !entry.isIntersecting && window.innerWidth > 1200)
      },
      { threshold: 0, rootMargin: '-80px 0px 0px 0px' }
    )
    obs.observe(hero)
  }

  // Active section tracking
  const sectionObs = new IntersectionObserver(
    (entries) => {
      for (const entry of entries) {
        if (entry.isIntersecting) {
          const id = entry.target.id
          for (const link of links) {
            link.classList.toggle('active', link.getAttribute('href') === '#' + id)
          }
        }
      }
    },
    { rootMargin: '-20% 0px -60% 0px', threshold: 0 }
  )

  for (const section of sections) {
    sectionObs.observe(section)
  }
}

// ── Section Reveal on Scroll ──────────────────────────────

function initSectionReveal() {
  const sections = Array.from(document.querySelectorAll('section'))

  // Reveal any section whose top is above the viewport bottom.
  // Uses getBoundingClientRect for reliable viewport-relative checks,
  // handling anchor jumps and normal scrolling alike.
  const reveal = () => {
    for (const section of sections) {
      const rect = section.getBoundingClientRect()
      if (rect.top < window.innerHeight + 100) {
        section.classList.add('in-view')
      }
    }
  }

  window.addEventListener('scroll', reveal, { passive: true })
  // Also run on hashchange (TOC clicks, xref clicks)
  window.addEventListener('hashchange', () => requestAnimationFrame(reveal))
  reveal()
}

// ── Copy Buttons ──────────────────────────────────────────

function initCopyButtons() {
  for (const btn of document.querySelectorAll('.code-copy')) {
    btn.addEventListener('click', async () => {
      const block = btn.closest('.code-block')
      const code = block?.querySelector('pre code')
      if (!code) return

      try {
        await navigator.clipboard.writeText(code.textContent)
        btn.textContent = 'copied'
        btn.classList.add('copied')
        setTimeout(() => {
          btn.textContent = 'copy'
          btn.classList.remove('copied')
        }, 1500)
      } catch {
        // Clipboard API might fail in some contexts
      }
    })
  }
}

// ── Cross-Reference Links ─────────────────────────────────

function initXrefLinks() {
  for (const link of document.querySelectorAll('a.xref')) {
    link.addEventListener('mouseenter', () => {
      const target = document.querySelector(link.getAttribute('href'))
      if (target) {
        target.style.transition = 'box-shadow 0.3s ease'
        target.style.boxShadow = 'inset 4px 0 0 var(--section)'
      }
    })
    link.addEventListener('mouseleave', () => {
      const target = document.querySelector(link.getAttribute('href'))
      if (target) {
        target.style.boxShadow = 'none'
      }
    })
  }
}
