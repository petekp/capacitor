"use client";

import { motion, useMotionValue, useTransform, animate } from "motion/react";
import { useEffect } from "react";

export default function LogomarkAnimated({ className }: { className?: string }) {
  const base = useMotionValue(0);

  useEffect(() => {
    // Slow, irregular oscillation — like a needle trying to push past a limit
    const controls = animate(base, [0, 1, 0.3, 0.85, 0.1, 0.95, 0.4, 0.7, 0.2, 0.9, 0], {
      duration: 6,
      repeat: Infinity,
      ease: "easeInOut",
    });
    return () => controls.stop();
  }, [base]);

  // Map 0-1 to a rotation range that sits near the "max" end
  // Biased high: mostly 8-15deg with occasional dips to ~3deg
  const rotate = useTransform(base, [0, 1], [3, 15]);

  // Subtle scale pulse — straining at capacity
  const scale = useTransform(base, [0, 0.5, 1], [0.98, 1.02, 0.99]);

  return (
    <motion.svg
      className={className}
      viewBox="0 0 332 332"
      fill="none"
      xmlns="http://www.w3.org/2000/svg"
      style={{ rotate, scale }}
    >
      <path
        d="M166 0C205.597 0 241.956 13.8656 270.487 37.0049L151.955 155.538C145.121 162.372 145.121 173.452 151.955 180.286C158.789 187.12 169.87 187.12 176.704 180.286L295.211 61.7783C318.221 90.2696 332 126.525 332 166C332 257.679 257.679 332 166 332C74.3207 332 0 257.679 0 166C0 74.3207 74.3207 0 166 0Z"
        fill="#0FFF88"
      />
    </motion.svg>
  );
}
