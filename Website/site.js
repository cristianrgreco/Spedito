const showcaseSlides = [
  {
    file: "0-sprint-board-overview.webp",
    phase: "Deliver",
    title: "See your AI team at work.",
    caption:
      "See what’s moving, blocked, under review, and ready to demo—without asking agents for updates.",
    alt: "StoryPointless Sprint Board showing Tickets across Ready to Pick, In Progress, In Review, Ready for Demo, and Done.",
  },
  {
    file: "25-customize-your-team.webp",
    phase: "Adapt",
    title: "Customise the team",
    caption:
      "Tune team roles, models, effort, and instructions for the product.",
    alt: "StoryPointless team settings for roles, models, effort, and instructions.",
  },
  {
    file: "1-epic-ai-refinement.webp",
    phase: "Define",
    title: "Refine an Epic",
    caption:
      "Focused questions resolve the outcome, scope, constraints, and acceptance before delivery starts.",
    alt: "StoryPointless refining a rough Epic through focused Business Analyst questions.",
  },
  {
    file: "2-epic-ai-refined.webp",
    phase: "Define",
    title: "Review the refined Epic",
    caption:
      "The agreed outcome becomes a reviewable Epic before it creates Backlog work.",
    alt: "A refined StoryPointless Epic ready for the Product Owner to review.",
  },
  {
    file: "3-backlog-proposed.webp",
    phase: "Plan",
    title: "Build the Backlog",
    caption:
      "Turn the approved Epic into a prioritised Backlog with clear dependencies.",
    alt: "A StoryPointless Backlog with three proposed Tickets and their dependencies.",
  },
  {
    file: "6-sprint-plan.webp",
    phase: "Plan",
    title: "Plan the Sprint",
    caption: "Let dependencies and readiness shape a realistic Sprint.",
    alt: "StoryPointless proposing a Sprint plan from ready Backlog Tickets.",
  },
  {
    file: "9-sprint-agent-debug-info.webp",
    phase: "Deliver",
    title: "Follow the work",
    caption:
      "Open any run to understand useful activity without living in a terminal.",
    alt: "A StoryPointless Ticket showing concise live agent activity and run details.",
  },
  {
    file: "10-access-request.webp",
    phase: "Control",
    title: "Keep access scoped",
    caption:
      "Approve the smallest exact capability when an agent needs more access.",
    alt: "A scoped agent permission request inside StoryPointless.",
  },
  {
    file: "11-questions-during-ticket.webp",
    phase: "Deliver",
    title: "Resolve product questions",
    caption:
      "Answer consequential questions inside the Ticket Work log while delivery continues.",
    alt: "A StoryPointless Ticket asking the Product Owner a delivery question.",
  },
  {
    file: "12-chat-with-your-team.webp",
    phase: "Collaborate",
    title: "Chat with the team",
    caption:
      "Talk to the whole AI team without juggling separate chat threads.",
    alt: "The StoryPointless team Conversation with several AI team members.",
  },
  {
    file: "13-tech-lead-review.webp",
    phase: "Review",
    title: "Review independently",
    caption:
      "A Tech Lead reviews the exact delivery candidate independently.",
    alt: "A Tech Lead review running against a StoryPointless Ticket candidate.",
  },
  {
    file: "14-tech-lead-review-issues-found.webp",
    phase: "Review",
    title: "Fix review findings",
    caption:
      "Findings return to the Ticket instead of disappearing into chat context.",
    alt: "Tech Lead review findings recorded in a StoryPointless Ticket Work log.",
  },
  {
    file: "16-agents-have-appropriate-context.webp",
    phase: "Context",
    title: "Give agents context",
    caption:
      "Each agent receives its Ticket, direct handoffs, and relevant Product knowledge.",
    alt: "StoryPointless showing the focused context supplied to a delivery agent.",
  },
  {
    file: "17-product-knowledge-building.webp",
    phase: "Learn",
    title: "Build Product knowledge",
    caption:
      "Useful decisions become verified Product knowledge while the team works.",
    alt: "StoryPointless Product knowledge growing from verified delivery decisions.",
  },
  {
    file: "18-demo.webp",
    phase: "Demo",
    title: "Prepare the Demo",
    caption: "Launch the exact reviewed result directly from the Ticket.",
    alt: "A reviewed StoryPointless Ticket with its working Demo ready to launch.",
  },
  {
    file: "19-demo-result.webp",
    phase: "Demo",
    title: "Try the result",
    caption: "Use the working product before deciding whether to accept it.",
    alt: "The working result launched from a StoryPointless Demo.",
  },
  {
    file: "20-auto-conflict-resolution-with-review.webp",
    phase: "Review",
    title: "Automatic conflict resolution",
    caption:
      "Changes made during conflict resolution are reviewed before integration continues.",
    alt: "StoryPointless coordinating conflict resolution and focused Tech Lead re-review.",
  },
  {
    file: "22-code.webp",
    phase: "Inspect",
    title: "Inspect the code",
    caption:
      "Code stays available when you want it, without becoming the primary workflow.",
    alt: "The optional code browser inside StoryPointless.",
  },
  {
    file: "23-retrospective.webp",
    phase: "Improve",
    title: "Run the Retrospective",
    caption:
      "Turn Sprint evidence into strengths, improvements, and reviewable actions.",
    alt: "A StoryPointless Retrospective with evidence and proposed actions.",
  },
  {
    file: "24-reports.webp",
    phase: "Learn",
    title: "Learn from reports",
    caption: "Make delivery patterns visible across Sprints.",
    alt: "StoryPointless Reports showing delivery patterns and team performance.",
  },
];

const showcase = document.querySelector("[data-showcase]");

if (showcase) {
  const title = showcase.querySelector("[data-showcase-title]");
  const count = showcase.querySelector("[data-showcase-count]");
  const stage = showcase.querySelector("[data-showcase-stage]");
  const image = showcase.querySelector("[data-showcase-image]");
  const previousPreview = showcase.querySelector(
    "[data-showcase-previous-preview]",
  );
  const nextPreview = showcase.querySelector("[data-showcase-next-preview]");
  const previousImage = showcase.querySelector(
    "[data-showcase-previous-image]",
  );
  const nextImage = showcase.querySelector("[data-showcase-next-image]");
  const openImage = showcase.querySelector("[data-showcase-open]");
  const lightbox = document.querySelector("[data-showcase-lightbox]");
  const lightboxImage = lightbox.querySelector(
    "[data-showcase-lightbox-image]",
  );
  const lightboxPrevious = lightbox.querySelector(
    "[data-showcase-lightbox-previous]",
  );
  const lightboxNext = lightbox.querySelector(
    "[data-showcase-lightbox-next]",
  );
  const closeLightbox = lightbox.querySelector("[data-showcase-close]");
  const phase = showcase.querySelector("[data-showcase-phase]");
  const caption = showcase.querySelector("[data-showcase-caption]");
  const previous = showcase.querySelector("[data-showcase-previous]");
  const next = showcase.querySelector("[data-showcase-next]");
  const reduceMotion = window.matchMedia(
    "(prefers-reduced-motion: reduce)",
  ).matches;
  let currentIndex = 0;
  let swipeStart;
  let lastWheelAt = 0;
  let animationTimer;
  let suppressOpen = false;

  const wrap = (index) =>
    (index + showcaseSlides.length) % showcaseSlides.length;

  const animateStage = (direction) => {
    if (reduceMotion || !direction) {
      return;
    }

    stage.classList.remove("is-moving-next", "is-moving-previous");
    void stage.offsetWidth;
    stage.classList.add(`is-moving-${direction}`);
    window.clearTimeout(animationTimer);
    animationTimer = window.setTimeout(() => {
      stage.classList.remove("is-moving-next", "is-moving-previous");
    }, 420);
  };

  const activate = (requestedIndex, shouldAnimate = true) => {
    const nextIndex = wrap(requestedIndex);
    const direction =
      nextIndex === currentIndex
        ? undefined
        : requestedIndex > currentIndex
          ? "next"
          : "previous";
    currentIndex = nextIndex;
    const item = showcaseSlides[currentIndex];
    const previousItem = showcaseSlides[wrap(currentIndex - 1)];
    const nextItem = showcaseSlides[wrap(currentIndex + 1)];

    title.textContent = item.title;
    count.textContent = `${String(currentIndex + 1).padStart(2, "0")} / ${showcaseSlides.length}`;
    phase.textContent = item.phase;
    caption.textContent = item.caption;
    image.src = `./screenshots/${item.file}`;
    image.alt = item.alt;
    previousPreview.src = `./screenshots/${previousItem.file}`;
    nextPreview.src = `./screenshots/${nextItem.file}`;
    previousImage.setAttribute("aria-label", `Previous: ${previousItem.title}`);
    nextImage.setAttribute("aria-label", `Next: ${nextItem.title}`);
    lightboxPrevious.setAttribute(
      "aria-label",
      `Previous: ${previousItem.title}`,
    );
    lightboxNext.setAttribute("aria-label", `Next: ${nextItem.title}`);
    openImage.setAttribute("aria-label", `Open ${item.title} full size`);
    stage.setAttribute(
      "aria-label",
      `${item.title}, screenshot ${currentIndex + 1} of ${showcaseSlides.length}`,
    );
    if (lightbox.open) {
      lightboxImage.src = `./screenshots/${item.file}`;
      lightboxImage.alt = item.alt;
      lightbox.setAttribute("aria-label", `Full-size screenshot: ${item.title}`);
    }
    animateStage(shouldAnimate ? direction : undefined);
  };

  previous.addEventListener("click", () => activate(currentIndex - 1));
  next.addEventListener("click", () => activate(currentIndex + 1));
  previousImage.addEventListener("click", () => activate(currentIndex - 1));
  nextImage.addEventListener("click", () => activate(currentIndex + 1));

  const setPageScrollLocked = (isLocked) => {
    document.documentElement.classList.toggle(
      "showcase-lightbox-open",
      isLocked,
    );
  };

  const closeFullSize = () => {
    setPageScrollLocked(false);
    if (typeof lightbox.close === "function") {
      lightbox.close();
    } else {
      lightbox.removeAttribute("open");
    }
  };

  openImage.addEventListener("click", () => {
    if (suppressOpen) {
      return;
    }

    lightboxImage.src = image.currentSrc || image.src;
    lightboxImage.alt = image.alt;
    lightbox.setAttribute(
      "aria-label",
      `Full-size screenshot: ${showcaseSlides[currentIndex].title}`,
    );
    setPageScrollLocked(true);
    if (typeof lightbox.showModal === "function") {
      lightbox.showModal();
    } else {
      lightbox.setAttribute("open", "");
    }
  });

  closeLightbox.addEventListener("click", closeFullSize);
  lightboxPrevious.addEventListener("click", () =>
    activate(currentIndex - 1, false),
  );
  lightboxNext.addEventListener("click", () =>
    activate(currentIndex + 1, false),
  );
  lightbox.addEventListener("close", () => setPageScrollLocked(false));

  lightbox.addEventListener("click", (event) => {
    if (event.target === lightbox) {
      closeFullSize();
    }
  });

  lightbox.addEventListener("keydown", (event) => {
    if (event.key === "ArrowLeft") {
      event.preventDefault();
      activate(currentIndex - 1, false);
    } else if (event.key === "ArrowRight") {
      event.preventDefault();
      activate(currentIndex + 1, false);
    }
  });

  stage.addEventListener("keydown", (event) => {
    if (event.key === "ArrowLeft") {
      event.preventDefault();
      activate(currentIndex - 1);
    } else if (event.key === "ArrowRight") {
      event.preventDefault();
      activate(currentIndex + 1);
    } else if (event.key === "Home") {
      event.preventDefault();
      activate(0);
    } else if (event.key === "End") {
      event.preventDefault();
      activate(showcaseSlides.length - 1);
    }
  });

  stage.addEventListener("pointerdown", (event) => {
    if (event.pointerType !== "mouse") {
      swipeStart = event.clientX;
    }
  });

  stage.addEventListener("pointerup", (event) => {
    if (swipeStart === undefined) {
      return;
    }

    const distance = event.clientX - swipeStart;
    swipeStart = undefined;

    if (Math.abs(distance) < 45) {
      return;
    }

    suppressOpen = true;
    window.setTimeout(() => {
      suppressOpen = false;
    }, 0);
    activate(currentIndex + (distance < 0 ? 1 : -1));
  });

  stage.addEventListener("pointercancel", () => {
    swipeStart = undefined;
  });

  stage.addEventListener(
    "wheel",
    (event) => {
      if (
        Math.abs(event.deltaX) <= Math.abs(event.deltaY) ||
        Math.abs(event.deltaX) < 12
      ) {
        return;
      }

      event.preventDefault();
      const now = performance.now();
      if (now - lastWheelAt < 450) {
        return;
      }

      lastWheelAt = now;
      activate(currentIndex + (event.deltaX > 0 ? 1 : -1));
    },
    { passive: false },
  );

  activate(0, false);
}

const faq = document.querySelector("[data-faq]");

if (faq) {
  const items = [...faq.querySelectorAll("details")];
  const animations = new Map();
  const reduceMotion = window.matchMedia(
    "(prefers-reduced-motion: reduce)",
  ).matches;
  let foundOpenItem = false;

  items.forEach((item) => {
    if (!item.open) {
      return;
    }

    if (foundOpenItem) {
      item.open = false;
      return;
    }

    foundOpenItem = true;
  });

  const animateItem = (item, shouldOpen) => {
    const summary = item.querySelector("summary");
    const startHeight = item.getBoundingClientRect().height;

    if (shouldOpen) {
      item.open = true;
    }

    const endHeight = shouldOpen
      ? item.scrollHeight
      : summary.getBoundingClientRect().height + 1;

    item.style.height = `${startHeight}px`;
    item.style.overflow = "hidden";

    const animation = item.animate(
      {
        height: [`${startHeight}px`, `${endHeight}px`],
      },
      {
        duration: 280,
        easing: "cubic-bezier(0.22, 1, 0.36, 1)",
      },
    );

    animations.set(item, animation);

    animation.addEventListener(
      "finish",
      () => {
        item.open = shouldOpen;
        item.style.removeProperty("height");
        item.style.removeProperty("overflow");
        animations.delete(item);
      },
      { once: true },
    );
  };

  items.forEach((item) => {
    item.querySelector("summary").addEventListener("click", (event) => {
      event.preventDefault();

      if (animations.size > 0) {
        return;
      }

      const shouldOpen = !item.open;

      items.forEach((otherItem) => {
        if (otherItem !== item && otherItem.open) {
          if (reduceMotion) {
            otherItem.open = false;
          } else {
            animateItem(otherItem, false);
          }
        }
      });

      if (reduceMotion) {
        item.open = shouldOpen;
      } else {
        animateItem(item, shouldOpen);
      }
    });
  });
}

const tourLink = document.querySelector('a[href="#tour"]');
const tour = document.querySelector("#tour");

if (tourLink && tour) {
  tourLink.addEventListener("click", (event) => {
    if (
      event.button !== 0 ||
      event.metaKey ||
      event.ctrlKey ||
      event.shiftKey ||
      event.altKey
    ) {
      return;
    }

    event.preventDefault();
    const reduceMotion = window.matchMedia(
      "(prefers-reduced-motion: reduce)",
    ).matches;

    tour.scrollIntoView({
      behavior: reduceMotion ? "auto" : "smooth",
      block: "center",
      inline: "nearest",
    });
  });
}
