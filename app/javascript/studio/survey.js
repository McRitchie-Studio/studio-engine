// studio/survey: the survey stepper, a progressive enhancement over
// studio/surveys/show. It adds .is-enhanced and turns the page's own markup
// into one question at a time, with autosave. Plain DOM, no Alpine.
//
// IDEMPOTENT PER ROOT, so a second connect never double-binds. Bound roots are
// tracked in a WeakSet, never in a DOM attribute: Turbo's snapshot cache clones
// the page, and a clone keeps every attribute but none of the listeners, so a
// marker in the DOM would make a restored page look set up while it is dead.
//
// AUTOSAVE IS BEST EFFORT: the final Submit posts the whole form, so a failed
// autosave loses nothing. Without this module the page is the plain form, every
// question on one page, and it submits the same answers.
//
// It imports nothing; test/javascript/survey.test.mjs loads it as a data:
// module. Bound to the page by the survey controller.

var bound = new WeakSet();

export function typeOf(step) { return step.dataset.type || ""; }
export function isChoice(step) { return /^(emoji_scale|rating|choice)$/.test(typeOf(step)); }
export function isMulti(step) { return typeOf(step) === "multi_choice"; }
export function inputs(step) { return Array.prototype.slice.call(step.querySelectorAll("input.studio-survey__input")); }

// A step's answer: the checked values of a multi-choice, the checked value of
// a choice or scale, or the trimmed text. Blank is "" (or [] for a
// multi-choice).
export function valueOf(step) {
  if (isMulti(step)) return inputs(step).filter(function (i) { return i.checked; }).map(function (i) { return i.value; });
  if (isChoice(step)) {
    var picked = inputs(step).filter(function (i) { return i.checked; })[0];
    return picked ? picked.value : "";
  }
  var field = step.querySelector("[data-survey-text]");
  return field ? field.value.trim() : "";
}

export function answered(step) {
  var v = valueOf(step);
  return Array.isArray(v) ? v.length > 0 : v !== "";
}

// The progress bar's width for question `position` of `total`.
export function progressWidth(position, total) {
  return (total ? (position / total) * 100 : 0) + "%";
}

// Where the stepper opens. A fresh visitor lands on question 1; a returning
// one on their next question (resume-index is the question's own index, and
// every step is a question); a page restored from Turbo's cache on the step it
// was left on (`restored`, -1 when it was not restored).
export function startIndex(resume, total, restored) {
  var start = resume === "" || resume === undefined ? 0 : parseInt(resume, 10);
  if (!(start >= 0 && start < total)) start = 0;
  if (restored >= 0) start = restored;
  return start;
}

// Enhances one [data-studio-survey] root. Answers false for a root it has
// already bound.
export function enhanceSurvey(root, win = window, doc = document) {
  if (bound.has(root)) return false;
  bound.add(root);

  var form = root.querySelector("[data-survey-form]");
  var steps = Array.prototype.slice.call(root.querySelectorAll("[data-survey-step]"));
  // Every step is a question: the survey opens on question 1, no intro screen.
  var total = steps.length;
  var head = root.querySelector("[data-survey-head]");
  var back = root.querySelector("[data-survey-back]");
  var next = root.querySelector("[data-survey-next]");
  var submit = root.querySelector("[data-survey-submit]");
  var top = root.querySelector("[data-survey-top]");
  var bar = root.querySelector("[data-survey-progress]");
  var fill = root.querySelector("[data-survey-progress-fill]");
  var count = root.querySelector("[data-survey-count]");
  var status = root.querySelector("[data-survey-status]");
  var hint = root.querySelector("[data-survey-hint]");
  // A page restored from Turbo's cache comes back on the step it was left
  // on; resume there rather than at the server's original resume point.
  var restored = -1;
  // The GLOBAL token, not the form's: with per_form_csrf_tokens on, the
  // form's hidden token is bound to the POST and refused on the PATCH.
  var csrf = root.dataset.csrf || "";
  var reduce = win.matchMedia && win.matchMedia("(prefers-reduced-motion: reduce)").matches;
  var saved = {};
  var timers = {};
  var current = -1;
  var pointerPick = false;
  var submitting = false;

  form.noValidate = true;
  if (root.classList.contains("is-enhanced")) {
    Array.prototype.forEach.call(root.querySelectorAll("[data-survey-step]"), function (step, i) {
      if (step.classList.contains("is-active")) restored = i;
    });
  }
  root.classList.add("is-enhanced");
  top.hidden = false;

  function setError(step, message) {
    var el = step.querySelector("[data-survey-error]");
    if (!el) return;
    el.textContent = message || "";
    el.hidden = !message;
    step.classList.toggle("is-invalid", !!message);
  }

  function save(step) {
    var key = step.dataset.key;
    if (!key || submitting) return Promise.resolve(true);
    var value = valueOf(step);
    var fingerprint = JSON.stringify(value);
    if (saved[key] === fingerprint) return Promise.resolve(true);

    var body = new win.FormData();
    if (Array.isArray(value)) {
      if (value.length === 0) body.append("value[]", "");
      value.forEach(function (v) { body.append("value[]", v); });
    } else {
      body.append("value", value);
    }
    var url = root.dataset.answerBase + encodeURIComponent(key);
    status.textContent = "Saving…";
    return win.fetch(url, {
      method: "PATCH",
      body: body,
      credentials: "same-origin",
      headers: { "Accept": "application/json", "X-CSRF-Token": csrf }
    }).then(function (res) {
      // fetch resolves on a 4xx/5xx — the status is the only signal.
      if (!res.ok) {
        return res.json().catch(function () { return {}; }).then(function (data) {
          if (res.status === 422 && data.error) setError(step, data.error);
          status.textContent = "Not saved yet — your answers still go in when you submit.";
          return false;
        });
      }
      saved[key] = fingerprint;
      status.textContent = "Saved";
      return true;
    }).catch(function () {
      status.textContent = "Offline? Your answers still go in when you submit.";
      return false;
    });
  }

  function render(index, direction) {
    steps.forEach(function (step, i) {
      var active = i === index;
      step.hidden = !active;
      step.classList.toggle("is-active", active);
      if (active) {
        if (direction && !reduce) step.dataset.dir = direction; else delete step.dataset.dir;
      }
    });
    current = index;
    var first = index === 0;
    var last = index === steps.length - 1;
    // Nothing comes before question 1, so it has no Back. Next keeps the
    // right edge on its own (margin-left: auto), so the row does not shift.
    back.hidden = first;
    next.hidden = last;
    submit.hidden = !last;
    // The title and intro lead question 1 only; later screens show the
    // question alone. The head steps into a visual clip rather than
    // `hidden`, so the page keeps its h1 for a screen reader on every step.
    if (head) head.classList.toggle("studio-survey__head--later", !first);
    // The number-key shortcut only means something on a choice or scale.
    var step = steps[index];
    hint.hidden = !(step.dataset.key && (isChoice(step) || isMulti(step)));

    var position = index + 1;
    fill.style.width = progressWidth(position, total);
    bar.setAttribute("aria-valuenow", String(position));
    count.textContent = "Question " + position + " of " + total;

    var focusTarget = steps[index].querySelector("[data-survey-focus]");
    if (focusTarget && direction) focusTarget.focus({ preventScroll: true });
    if (direction) win.scrollTo({ top: 0, behavior: reduce ? "auto" : "smooth" });
  }

  function go(index) {
    if (index < 0 || index >= steps.length || index === current) return;
    render(index, index > current ? "fwd" : "back");
  }

  function forward() {
    var step = steps[current];
    if (step.dataset.key) {
      if (step.dataset.required === "true" && !answered(step)) {
        setError(step, "This one is required.");
        var first = step.querySelector("input:not([type=hidden]), textarea");
        if (first) first.focus();
        return;
      }
      setError(step, "");
    }
    if (current === steps.length - 1) {
      // No autosave here: the POST carries every answer, and a PATCH racing
      // it would land after completion and be refused.
      submitForm();
    } else {
      if (step.dataset.key) save(step);
      go(current + 1);
    }
  }

  function submitForm() {
    if (form.requestSubmit) form.requestSubmit(submit); else form.submit();
  }

  // The first required question still missing an answer, for a Submit that
  // jumps ahead (Enter on the last step, or a mid-survey reload).
  form.addEventListener("submit", function (event) {
    for (var i = 0; i < steps.length; i++) {
      if (steps[i].dataset.required === "true" && !answered(steps[i])) {
        event.preventDefault();
        go(i);
        setError(steps[i], "This one is required.");
        return;
      }
    }
    Object.keys(timers).forEach(function (key) { win.clearTimeout(timers[key]); });
    submitting = true;
    submit.disabled = true;
    submit.textContent = "Sending…";
  });

  back.addEventListener("click", function () { go(current - 1); });
  next.addEventListener("click", forward);

  root.addEventListener("pointerdown", function (event) {
    pointerPick = !!event.target.closest("[data-survey-choice]");
  });

  root.addEventListener("change", function (event) {
    var step = event.target.closest("[data-survey-step]");
    if (!step || !step.dataset.key || step.hidden) return;
    setError(step, "");
    if (isChoice(step)) {
      save(step);
      // Advance on a tap or a number key, never on arrow keys: arrows move
      // through a radio group and must not jump the reader off the question.
      if (pointerPick) {
        pointerPick = false;
        win.setTimeout(function () { if (steps[current] === step) forward(); }, reduce ? 0 : 260);
      }
    } else if (isMulti(step)) {
      save(step);
    }
  });

  root.addEventListener("input", function (event) {
    var field = event.target.closest("[data-survey-text]");
    if (!field) return;
    var step = field.closest("[data-survey-step]");
    var counter = step.querySelector("[data-survey-counter]");
    if (counter) counter.textContent = String(field.value.length);
    win.clearTimeout(timers[step.dataset.key]);
    timers[step.dataset.key] = win.setTimeout(function () { save(step); }, 900);
  });

  function onKey(event) {
    if (event.defaultPrevented || event.altKey) return;
    // A tap on an already-chosen option fires pointerdown but no change, so
    // the flag would outlive it and make the next arrow key advance.
    pointerPick = false;
    var step = steps[current];
    var target = event.target;
    var inText = target.matches && target.matches("textarea, input[type=text]");

    if (event.key === "Enter") {
      if (target.tagName === "BUTTON" || target.tagName === "A") return;
      if (target.tagName === "TEXTAREA" && !(event.metaKey || event.ctrlKey)) return;
      event.preventDefault();
      forward();
      return;
    }

    if (inText || event.metaKey || event.ctrlKey || !/^[1-9]$/.test(event.key)) return;
    if (!step.dataset.key || !(isChoice(step) || isMulti(step))) return;
    var option = inputs(step)[parseInt(event.key, 10) - 1];
    if (!option) return;
    event.preventDefault();
    option.checked = isMulti(step) ? !option.checked : true;
    option.focus({ preventScroll: true });
    pointerPick = isChoice(step);
    option.dispatchEvent(new win.Event("change", { bubbles: true }));
  }

  root.addEventListener("keydown", onKey);
  // The survey opens on question 1 with nothing focused, so a first key
  // lands on <body>, outside the root. Take those keys too, and only those:
  // a key aimed at any other control on the page is not the survey's. The
  // listener retires itself once a Turbo visit has taken this root away.
  function onPageKey(event) {
    if (!root.isConnected) { doc.removeEventListener("keydown", onPageKey); return; }
    var target = event.target;
    if (target === doc.body || target === doc.documentElement) onKey(event);
  }
  doc.addEventListener("keydown", onPageKey);

  var hasErrors = root.dataset.hasErrors === "true";
  // A failed submit lands on the first question it flagged: the server sets
  // resume-index to it.
  var start = startIndex(root.dataset.resumeIndex, steps.length, restored);
  render(start, null);
  if (restored < 0 && (start > 0 || hasErrors)) {
    var focusTarget = steps[current].querySelector("[data-survey-focus]");
    if (focusTarget) focusTarget.focus({ preventScroll: true });
    if (start > 0 && !hasErrors) status.textContent = "Welcome back — picking up where you left off.";
  }
  // Answers already on the page are already stored.
  steps.forEach(function (step) { if (step.dataset.key) saved[step.dataset.key] = JSON.stringify(valueOf(step)); });
  return true;
}
