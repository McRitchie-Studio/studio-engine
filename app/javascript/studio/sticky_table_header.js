// studio/sticky_table_header: pins a cloned header row over a long table as it
// scrolls under the navbar (docs/NAVBAR_SETUP.md). An ES module that installs on
// import: the head loads it with a type="module" tag when
// Studio.sticky_table_headers is on (or the head's sticky_table_headers local
// says so). Its default export is window.StudioStickyTableHeaders
// ({ loaded, pinnedEdge, placement }), which stays as the compatibility global
// (CHANGELOG, "Deprecated"). The body stays one function with no import, so
// test/javascript/sticky_table_header.test.mjs still runs it in a node:vm
// context per test (cutting the single export line).
(() => {
  if (window.StudioStickyTableHeaders?.loaded) return;

  const MANUAL_TABLE_SELECTOR = "table[data-sticky-table-header]";
  const AUTO_TABLE_SELECTOR = "table";
  const SKIP_CONTAINER_SELECTOR = "[data-sticky-table-skip]";
  // What studio/nav_collapse fires when a scroll-timeline header starts,
  // re-measures its band, or stops: the header's PINNED height changed without
  // its box resizing, so no ResizeObserver and no scroll hears of it.
  const PINNED_STACK_REFRESH = "studio:pinned-stack-refresh";
  // What studio/pinned_stack fires after every publish that moved the stack.
  const PINNED_STACK_PUBLISHED = "studio:pinned-stack-published";

  let stickyTables = [];
  let scheduled = false;
  let bootScheduled = false;
  let pinResizeObserver = null;
  let tableMutationObserver = null;

  // WHERE THE CLONE STARTS: THE PINNED STACK'S BOTTOM EDGE, read live.
  //
  // This used to read --nav-h off the root, and that was wrong twice. --nav-h
  // is the header's HEIGHT, not its bottom edge, so chrome stacked above the
  // header put the clone that much too high. And a root custom property is a
  // SNAPSHOT this script re-read only on scroll, resize or a header resize: on
  // a scroll-timeline header the compact height is published only once the
  // nav-collapse controller starts, which resizes nothing, so a page loaded at
  // a restored scroll position kept the clone at the expanded height (Turf
  // Monster /contests: 96px against a 50px bar, rows showing in the gap) until
  // the first scroll.
  //
  // window.studioPinnedStack.read() measures on call, the same reading the
  // publisher makes. On a scroll-timeline header it reports where the stack
  // sits once PINNED; at the top of the page the expanded header still reaches
  // `travel` further down, and closes that gap as the page scrolls, exactly as
  // engine.css's data-pin-edge does for a fixed reader in CSS. A host that never
  // started the publisher falls back to --pin-stack-bottom, then to 0: a clone
  // at the top of the viewport rather than none.
  function pinnedEdge(reading) {
    const r = reading || window.studioPinnedStack?.read?.();
    if (!r) {
      const raw = getComputedStyle(document.documentElement).getPropertyValue("--pin-stack-bottom");
      return Number.parseFloat(raw) || 0;
    }
    const bottom = Number(r.bottom) || 0;
    if (!r.timeline) return bottom;
    return bottom + Math.max(0, (Number(r.travel) || 0) - Math.max(0, window.scrollY));
  }

  // Where the clone goes for one table, as a pure function of what was measured:
  // shown once the real header has scrolled up to the edge, and pushed up by the
  // table's own bottom so it leaves with the table.
  function placement({ edge, headerTop, tableBottom, cloneHeight }) {
    const active = headerTop <= edge && tableBottom > edge;
    return { active, top: active ? Math.min(edge, tableBottom - cloneHeight) : null };
  }

  window.StudioStickyTableHeaders = { loaded: true, pinnedEdge, placement };

  // One pass over every table, reading the edge ONCE. Called from a frame
  // callback (scroll, resize, a stack event) and SYNCHRONOUSLY from the
  // ResizeObserver, which runs after layout and before paint: a script-mode
  // header changes height every frame of its collapse (studio/nav_collapse
  // writes --nav-p from its own frame callback, after ours), and a frame-late
  // clone shows rows through the gap for that frame.
  function updateAll(reading) {
    if (!stickyTables.length) return;
    const edge = pinnedEdge(reading);
    stickyTables.slice().forEach((stickyTable) => stickyTable.update(edge));
  }

  function scheduleUpdate() {
    if (scheduled) return;
    scheduled = true;
    requestAnimationFrame(() => {
      scheduled = false;
      updateAll();
    });
  }

  function scheduleBoot() {
    if (bootScheduled) return;
    bootScheduled = true;
    requestAnimationFrame(() => {
      bootScheduled = false;
      bootStickyTables();
    });
  }

  class StickyTableHeader {
    constructor(table) {
      this.table = table;
      this.prepareTable();
      this.scroller = table.closest("[data-sticky-table-scroll]") || table.parentElement;
      this.cloneShell = document.createElement("div");
      this.cloneShell.className = "sticky-table-header-clone";
      this.cloneShell.setAttribute("aria-hidden", "true");

      this.cloneTable = document.createElement("table");
      this.cloneTable.className = table.className;
      this.cloneTable.innerHTML = table.tHead ? table.tHead.outerHTML : "";
      this.cloneShell.appendChild(this.cloneTable);
      document.body.appendChild(this.cloneShell);

      this.scroller?.addEventListener("scroll", scheduleUpdate, { passive: true });
    }

    prepareTable() {
      this.table.classList.add("sticky-data-table");
      if (!this.table.hasAttribute("data-sticky-table-header")) {
        this.table.setAttribute("data-sticky-table-header", "auto");
      }

      const scroller = this.table.closest("[data-sticky-table-scroll]") || this.table.parentElement;
      if (scroller && !scroller.hasAttribute("data-sticky-table-scroll")) {
        scroller.setAttribute("data-sticky-table-scroll", "auto");
      }
    }

    destroy() {
      this.scroller?.removeEventListener("scroll", scheduleUpdate);
      this.cloneShell.remove();
    }

    syncColumnWidths() {
      const originalCells = this.table.tHead?.querySelectorAll("th") || [];
      const cloneCells = this.cloneTable.tHead?.querySelectorAll("th") || [];
      originalCells.forEach((cell, index) => {
        if (!cloneCells[index]) return;
        cloneCells[index].style.width = `${cell.getBoundingClientRect().width}px`;
      });
    }

    update(edge = pinnedEdge()) {
      if (!document.body.contains(this.table) || !this.table.tHead || !this.scroller) {
        this.destroy();
        stickyTables = stickyTables.filter((stickyTable) => stickyTable !== this);
        return;
      }

      const headerRect = this.table.tHead.getBoundingClientRect();
      const tableRect = this.table.getBoundingClientRect();
      const scrollerRect = this.scroller.getBoundingClientRect();
      const cloneHeight = headerRect.height || this.cloneShell.getBoundingClientRect().height;
      const { active, top } = placement({
        edge, headerTop: headerRect.top, tableBottom: tableRect.bottom, cloneHeight
      });

      if (!active) {
        this.cloneShell.style.display = "none";
        this.table.removeAttribute("data-sticky-table-active");
        return;
      }

      this.syncColumnWidths();

      const translateX = tableRect.left - scrollerRect.left;

      this.cloneShell.style.display = "block";
      this.cloneShell.style.left = `${scrollerRect.left}px`;
      this.cloneShell.style.top = `${top}px`;
      this.cloneShell.style.width = `${scrollerRect.width}px`;
      this.cloneShell.style.height = `${cloneHeight}px`;
      this.cloneTable.style.width = `${tableRect.width}px`;
      this.cloneTable.style.transform = `translateX(${translateX}px)`;
      this.table.setAttribute("data-sticky-table-active", "true");
    }
  }

  function bootStickyTables() {
    startTableObserver();

    // EVERY LAYER OF THE PINNED STACK, not the header alone: a bar above the
    // header that grows or goes moves the edge too. Re-observed on every boot.
    if (pinResizeObserver) pinResizeObserver.disconnect();
    pinResizeObserver = null;
    if (window.ResizeObserver) {
      const layers = new Set(document.querySelectorAll("[data-pin]"));
      const header = document.querySelector("header");
      if (header) layers.add(header);
      if (layers.size) {
        pinResizeObserver = new ResizeObserver(() => updateAll());
        layers.forEach((layer) => pinResizeObserver.observe(layer));
      }
    }

    stickyTables.forEach((stickyTable) => stickyTable.destroy());
    stickyTables = stickyTableCandidates().map((table) => new StickyTableHeader(table));
    scheduleUpdate();
  }

  function startTableObserver() {
    if (!window.MutationObserver || tableMutationObserver || !document.body) return;

    tableMutationObserver = new MutationObserver((mutations) => {
      const shouldReboot = mutations.some((mutation) => (
        Array.from(mutation.addedNodes).some(nodeContainsCandidateTable) ||
        Array.from(mutation.removedNodes).some(nodeContainsCandidateTable)
      ));

      if (shouldReboot) scheduleBoot();
    });

    tableMutationObserver.observe(document.body, { childList: true, subtree: true });
  }

  function nodeContainsCandidateTable(node) {
    if (node.nodeType !== Node.ELEMENT_NODE) return false;
    if (node.matches(".sticky-table-header-clone") || node.closest(".sticky-table-header-clone")) return false;

    return node.matches("table, thead, th") || Boolean(node.querySelector("table, thead, th"));
  }

  function stickyTableCandidates() {
    const candidates = [];
    const seen = new Set();

    document.querySelectorAll(`${MANUAL_TABLE_SELECTOR}, ${AUTO_TABLE_SELECTOR}`).forEach((table) => {
      if (seen.has(table) || !shouldEnhanceTable(table)) return;
      seen.add(table);
      candidates.push(table);
    });

    return candidates;
  }

  function shouldEnhanceTable(table) {
    if (table.getAttribute("data-sticky-table-header") === "false") return false;
    if (table.closest(SKIP_CONTAINER_SELECTOR)) return false;
    if (table.closest(".sticky-table-header-clone")) return false;
    if (table.closest("template")) return false;
    if (table.getAttribute("role")?.toLowerCase() === "presentation") return false;
    if (!table.tHead || !table.tHead.querySelector("th")) return false;
    // A table whose header cells are already position:sticky pins itself (usually
    // inside its own scroll container). Cloning it doubles the header — and the
    // activation math misfires there: the in-flow thead box scrolls under the nav
    // while the sticky th cells stay pinned and visible.
    if (getComputedStyle(table.tHead.querySelector("th")).position === "sticky") return false;

    return true;
  }

  document.addEventListener("turbo:load", bootStickyTables);
  document.addEventListener("DOMContentLoaded", bootStickyTables);
  document.addEventListener("turbo:before-cache", () => {
    if (pinResizeObserver) pinResizeObserver.disconnect();
    if (tableMutationObserver) tableMutationObserver.disconnect();
    pinResizeObserver = null;
    tableMutationObserver = null;
    stickyTables.forEach((stickyTable) => stickyTable.destroy());
    stickyTables = [];
  });
  // A STACK REPUBLISH RE-PLACES THE CLONE. The refresh is the timeline header
  // changing its pinned height (on start, which is the restored-scroll case);
  // the publish carries the reading the publisher just made, so the clone moves
  // in the same frame and with the same number.
  document.addEventListener(PINNED_STACK_REFRESH, scheduleUpdate);
  document.addEventListener(PINNED_STACK_PUBLISHED, (event) => updateAll(event.detail || undefined));
  window.addEventListener("scroll", scheduleUpdate, { passive: true });
  window.addEventListener("resize", scheduleUpdate, { passive: true });
})();

export default window.StudioStickyTableHeaders
