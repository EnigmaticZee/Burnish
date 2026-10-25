// Burnish's homepage: scroll reveals, the copy button, and the menu bar scene in the hero.
// Without this script the page still reads top to bottom; with reduced motion, nothing moves.
(() => {
  const reduceMotion = matchMedia("(prefers-reduced-motion: reduce)").matches;
  document.documentElement.classList.add("js");

  // Sections fade up as they arrive.
  const revealer = new IntersectionObserver((entries) => {
    for (const entry of entries) {
      if (entry.isIntersecting) {
        entry.target.classList.add("in");
        revealer.unobserve(entry.target);
      }
    }
  }, { threshold: 0.15, rootMargin: "0px 0px -40px 0px" });
  document.querySelectorAll(".reveal").forEach((el) => revealer.observe(el));

  // The marquee loops by showing its items twice.
  const track = document.querySelector(".marquee-track");
  if (track) {
    for (const item of [...track.children]) {
      const copy = item.cloneNode(true);
      copy.setAttribute("aria-hidden", "true");
      track.appendChild(copy);
    }
  }

  // Copy the Terminal command.
  document.querySelectorAll("[data-copy]").forEach((button) => {
    button.addEventListener("click", async () => {
      const text = document.querySelector(button.dataset.copy)?.textContent ?? "";
      try {
        await navigator.clipboard.writeText(text);
        button.textContent = "Copied";
      } catch {
        button.textContent = "Select and copy";
      }
      setTimeout(() => { button.textContent = "Copy"; }, 1800);
    });
  });

  if (reduceMotion) return;

  // The hero: the bell rings, Burnish checks, four updates arrive, Update All installs them.
  const $ = (id) => document.getElementById(id);
  const bell = $("bell"), count = $("count"), popover = $("popover"), title = $("pop-title"), sub = $("pop-sub");
  const bar = $("progress"), done = $("done"), updateAll = $("update-all");
  const rows = [...document.querySelectorAll("#rows li")];
  const stage = document.querySelector(".hero-stage");
  if (!bell || !popover || !stage) return;

  let onScreen = true;
  new IntersectionObserver(([entry]) => { onScreen = entry.isIntersecting; }).observe(stage);
  const sleep = (ms) => new Promise((resolve) => setTimeout(resolve, ms));
  // Pauses between steps while the scene is scrolled away or the tab is hidden.
  const wait = async (ms) => {
    await sleep(ms);
    while (!onScreen || document.hidden) await sleep(400);
  };
  const ring = () => {
    bell.classList.remove("ringing");
    void bell.offsetWidth;
    bell.classList.add("ringing");
  };
  const plural = (n) => (n === 1 ? "1 update" : `${n} updates`);

  async function play() {
    popover.classList.add("closed");
    bell.classList.remove("open", "ringing");
    count.textContent = "";
    count.classList.add("zero");
    title.textContent = "Checking…";
    sub.textContent = "Checked 0 of 25 apps";
    bar.parentElement.classList.remove("hidden");
    bar.style.transition = "none";
    bar.style.width = "0";
    done.classList.remove("show");
    for (const row of rows) {
      row.className = "hidden";
      const pill = row.querySelector(".pill");
      pill.className = "pill";
      pill.textContent = "Update";
    }

    await wait(900);
    ring();
    await wait(450);
    bell.classList.add("open");
    popover.classList.remove("closed");
    await wait(350);
    bar.style.transition = "";
    bar.style.width = "100%";
    for (let n = 1; n <= 25; n++) {
      sub.textContent = `Checked ${n} of 25 apps`;
      await sleep(62);
    }
    await wait(250);
    bar.parentElement.classList.add("hidden");
    title.textContent = plural(4);
    sub.textContent = "Checked just now";
    count.textContent = "4";
    count.classList.remove("zero");
    ring();
    for (const row of rows) {
      row.classList.remove("hidden");
      await sleep(150);
    }

    await wait(1500);
    updateAll.classList.add("pressed");
    await sleep(180);
    updateAll.classList.remove("pressed");
    let left = rows.length;
    for (const row of rows) {
      const pill = row.querySelector(".pill");
      pill.className = "pill working";
      pill.textContent = "Verifying";
      await wait(700);
      pill.className = "pill ok";
      pill.textContent = "Done ✓";
      left -= 1;
      count.textContent = String(left);
      title.textContent = left ? plural(left) : "Up to date";
      await sleep(220);
    }

    await wait(600);
    for (const row of rows) row.classList.add("gone");
    count.classList.add("zero");
    done.classList.add("show");
    sub.textContent = "All 25 apps current";
    await wait(2800);
    popover.classList.add("closed");
    bell.classList.remove("open");
    await wait(1400);
  }

  (async () => {
    for (;;) await play();
  })();
})();
