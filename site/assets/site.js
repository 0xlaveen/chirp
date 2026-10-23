// Chirp site: theme toggle, tabs, screenshot reels, copy buttons and the hero HUD demo. No network.
(() => {
  const doc = document.documentElement;
  doc.classList.add("js");
  const reduce = matchMedia("(prefers-reduced-motion: reduce)");

  // Theme: system → light → dark. Dark/light <source>s follow the choice, not just the OS.
  const modes = ["system", "light", "dark"];
  const store = (v) => { try { v === "system" ? localStorage.removeItem("chirp-theme") : localStorage.setItem("chirp-theme", v); } catch (e) {} };
  const applyTheme = (mode) => {
    if (mode === "system") delete doc.dataset.theme; else doc.dataset.theme = mode;
    const media = mode === "dark" ? "all" : mode === "light" ? "not all" : "(prefers-color-scheme: dark)";
    document.querySelectorAll("source[data-theme-src]").forEach((s) => s.setAttribute("media", media));
    document.querySelectorAll("[data-theme-toggle]").forEach((b) => {
      b.dataset.mode = mode;
      b.setAttribute("aria-label", `Colour theme: ${mode}. Switch to ${modes[(modes.indexOf(mode) + 1) % 3]}`);
    });
  };
  const current = () => doc.dataset.theme || "system";

  document.addEventListener("DOMContentLoaded", () => {
    applyTheme(current());
    document.querySelectorAll("[data-theme-toggle]").forEach((b) => b.addEventListener("click", () => {
      const next = modes[(modes.indexOf(current()) + 1) % 3];
      store(next);
      applyTheme(next);
    }));

    // Tabs (WAI-ARIA tabs pattern, automatic activation).
    document.querySelectorAll('[role="tablist"]').forEach((list) => {
      const tabs = [...list.querySelectorAll('[role="tab"]')];
      const select = (tab, focus) => {
        tabs.forEach((t) => {
          const on = t === tab;
          t.setAttribute("aria-selected", on);
          t.tabIndex = on ? 0 : -1;
          document.getElementById(t.getAttribute("aria-controls")).hidden = !on;
        });
        if (focus) tab.focus();
      };
      tabs.forEach((t, i) => {
        t.addEventListener("click", () => select(t));
        t.addEventListener("keydown", (e) => {
          const d = { ArrowRight: 1, ArrowLeft: -1, Home: -i, End: tabs.length - 1 - i }[e.key];
          if (d === undefined) return;
          e.preventDefault();
          select(tabs[(i + d + tabs.length) % tabs.length], true);
        });
      });
      select(tabs.find((t) => t.getAttribute("aria-selected") === "true") || tabs[0]);
    });

    // Screenshot reels: native scroll-snap, plus previous/next buttons.
    document.querySelectorAll(".reel").forEach((reel) => {
      const nav = reel.nextElementSibling;
      if (!nav || !nav.classList.contains("reel-nav")) return;
      const [prev, next] = nav.querySelectorAll("button");
      const update = () => {
        prev.disabled = reel.scrollLeft < 4;
        next.disabled = reel.scrollLeft + reel.clientWidth > reel.scrollWidth - 4;
        nav.hidden = reel.scrollWidth <= reel.clientWidth + 4;
      };
      const step = (dir) => reel.scrollBy({ left: dir * reel.clientWidth * 0.8, behavior: reduce.matches ? "auto" : "smooth" });
      prev.addEventListener("click", () => step(-1));
      next.addEventListener("click", () => step(1));
      reel.addEventListener("scroll", update, { passive: true });
      addEventListener("resize", update);
      new ResizeObserver(update).observe(reel);
      reel.querySelectorAll("img").forEach((img) => img.addEventListener("load", update));
    });

    // Copy buttons on code blocks.
    document.querySelectorAll("pre[data-copy]").forEach((pre) => {
      const btn = document.createElement("button");
      btn.type = "button";
      btn.className = "copy";
      btn.textContent = "Copy";
      btn.setAttribute("aria-label", pre.dataset.copy || "Copy to clipboard");
      btn.addEventListener("click", async () => {
        const text = pre.querySelector("code").innerText.trim();
        try { await navigator.clipboard.writeText(text); btn.textContent = "Copied"; }
        catch (e) { btn.textContent = "Select and copy"; }
        setTimeout(() => (btn.textContent = "Copy"), 1800);
      });
      pre.append(btn);
    });

    document.querySelectorAll(".hud[data-demo]").forEach(runHud);
  });

  // Hero HUD: the Mac capsule's real sequence — live words with a dimmed tail, polishing, the diff, inserted.
  function runHud(hud) {
    const status = hud.querySelector("[data-status]");
    const text = hud.querySelector("[data-text]");
    const words = "please move the standup to three thirty and uh let everyone know".split(" ");
    const diff = '<ins>Move</ins> the standup to <del>three thirty</del> <ins>3:30</ins> and <del>uh</del> let everyone <ins>know.</ins>';
    const done = "Move the standup to 3:30 and let everyone know.";
    const phase = (p, label, body) => { hud.dataset.phase = p; status.textContent = label; if (body !== undefined) text.innerHTML = body; };
    if (reduce.matches) return phase("polished", "Polished", diff);
    let visible = true, timer = 0, i = 0, stage = 0;
    const live = (n) => {
      const stable = words.slice(0, Math.max(0, n - 3)).join(" ");
      const tail = words.slice(Math.max(0, n - 3), n).join(" ");
      return `${stable}${stable && tail ? " " : ""}<span class="tail">${tail}</span>`;
    };
    const tick = () => {
      if (!visible || document.hidden) { timer = setTimeout(tick, 400); return; }
      if (stage === 0) {
        if (i === 0) phase("listening", "Listening", "");
        i++;
        text.innerHTML = live(i);
        if (i >= words.length) { stage = 1; i = 0; }
        return (timer = setTimeout(tick, i === 0 ? 700 : 230 + Math.random() * 120));
      }
      const steps = [
        () => [phase("listening", "Listening", words.join(" ")), 500],
        () => [phase("polishing", "Polishing"), 1100],
        () => [phase("polished", "Polished", diff), 2800],
        () => [phase("inserted", "Inserted", done), 2200],
      ];
      const [, wait] = steps[stage - 1]();
      stage = stage === steps.length ? 0 : stage + 1;
      timer = setTimeout(tick, wait);
    };
    new IntersectionObserver((e) => { visible = e[0].isIntersecting; }).observe(hud);
    reduce.addEventListener("change", () => { if (reduce.matches) { clearTimeout(timer); phase("polished", "Polished", diff); } });
    tick();
  }
})();
