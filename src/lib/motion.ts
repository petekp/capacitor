import type { Transition, Variants } from "motion/react";

// Base tempo in seconds - the "beat" of our motion rhythm
const BEAT = 0.15;

// Spring configurations - organic, musical movement
export const springs = {
  // Quick, snappy - like a staccato note
  snappy: { type: "spring", stiffness: 500, damping: 30 } as const,
  // Smooth, flowing - like a legato phrase
  smooth: { type: "spring", stiffness: 300, damping: 25 } as const,
  // Bouncy, playful - like a pizzicato
  bouncy: { type: "spring", stiffness: 400, damping: 15 } as const,
  // Gentle, settling - like a fermata
  gentle: { type: "spring", stiffness: 200, damping: 20 } as const,
};

// Duration-based transitions for when springs aren't right
export const durations = {
  instant: BEAT,
  quick: BEAT * 1.5,
  normal: BEAT * 2,
  slow: BEAT * 3,
  dramatic: BEAT * 4,
};

// Easing curves - quick attack, smooth decay (like musical dynamics)
export const easings = {
  // Standard - quick start, gentle end
  default: [0.22, 0.61, 0.36, 1] as const,
  // Punchy - very quick start, long tail
  punch: [0.16, 1, 0.3, 1] as const,
  // Soft - gentle start and end
  soft: [0.4, 0, 0.2, 1] as const,
  // Exit - accelerate out
  exit: [0.4, 0, 1, 1] as const,
};

// Stagger configurations for list animations
export const stagger = {
  // Quick succession - like rapid notes
  fast: 0.03,
  // Normal rhythm
  normal: 0.05,
  // Deliberate, spaced - like sustained notes
  slow: 0.08,
};

// Pre-built transition presets
export const transitions: Record<string, Transition> = {
  snappy: { ...springs.snappy },
  smooth: { ...springs.smooth },
  fade: { duration: durations.quick, ease: easings.default },
  scale: { ...springs.bouncy },
  slide: { ...springs.smooth },
};

// Card animation variants
export const cardVariants: Variants = {
  initial: {
    opacity: 0,
    y: 8,
    scale: 0.98,
  },
  animate: {
    opacity: 1,
    y: 0,
    scale: 1,
  },
  exit: {
    opacity: 0,
    y: -4,
    scale: 0.98,
  },
  hover: {
    y: -2,
    scale: 1.01,
    transition: springs.snappy,
  },
  tap: {
    scale: 0.99,
    transition: { duration: 0.1 },
  },
};

// Flash/pulse animation for state changes
export const flashVariants: Variants = {
  idle: {
    boxShadow: "0 0 0 0 transparent",
  },
  ready: {
    boxShadow: [
      "0 0 0 0 oklch(0.75 0.18 145 / 0)",
      "0 0 0 4px oklch(0.75 0.18 145 / 0.4)",
      "0 0 0 8px oklch(0.75 0.18 145 / 0)",
    ],
    transition: {
      duration: 0.6,
      times: [0, 0.5, 1],
      ease: easings.soft,
    },
  },
  compacting: {
    boxShadow: [
      "0 0 0 0 oklch(0.7 0.15 60 / 0)",
      "0 0 0 4px oklch(0.7 0.15 60 / 0.3)",
      "0 0 0 8px oklch(0.7 0.15 60 / 0)",
    ],
    transition: {
      duration: 0.8,
      times: [0, 0.5, 1],
      ease: easings.soft,
    },
  },
  error: {
    boxShadow: [
      "0 0 0 0 oklch(0.65 0.2 25 / 0)",
      "0 0 0 4px oklch(0.65 0.2 25 / 0.4)",
      "0 0 0 8px oklch(0.65 0.2 25 / 0)",
    ],
    transition: {
      duration: 0.5,
      times: [0, 0.5, 1],
      ease: easings.soft,
    },
  },
};

// Tab indicator animation
export const tabIndicatorVariants: Variants = {
  inactive: {
    scaleX: 0,
    opacity: 0,
  },
  active: {
    scaleX: 1,
    opacity: 1,
    transition: springs.snappy,
  },
};

// Panel transition variants
export const panelVariants: Variants = {
  initial: {
    opacity: 0,
    x: 20,
  },
  animate: {
    opacity: 1,
    x: 0,
    transition: {
      ...springs.smooth,
      staggerChildren: stagger.normal,
    },
  },
  exit: {
    opacity: 0,
    x: -20,
    transition: {
      duration: durations.quick,
      ease: easings.exit,
    },
  },
};

// List container variants for staggered children
export const listVariants: Variants = {
  initial: {},
  animate: {
    transition: {
      staggerChildren: stagger.fast,
      delayChildren: 0.05,
    },
  },
  exit: {
    transition: {
      staggerChildren: stagger.fast,
      staggerDirection: -1,
    },
  },
};

// Button press animation
export const buttonVariants: Variants = {
  idle: { scale: 1 },
  hover: { scale: 1.02, transition: springs.snappy },
  tap: { scale: 0.97, transition: { duration: 0.1 } },
};

// Loading pulse animation
export const pulseVariants: Variants = {
  animate: {
    opacity: [0.4, 0.7, 0.4],
    transition: {
      duration: 1.5,
      repeat: Infinity,
      ease: "easeInOut",
    },
  },
};

// Skeleton shimmer for loading states
export const shimmerVariants: Variants = {
  animate: {
    backgroundPosition: ["200% 0", "-200% 0"],
    transition: {
      duration: 1.5,
      repeat: Infinity,
      ease: "linear",
    },
  },
};
