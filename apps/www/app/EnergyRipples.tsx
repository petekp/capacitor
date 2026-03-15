"use client";

import { motion } from "motion/react";
import { useDialKit } from "dialkit";
import { useEffect, useState, useCallback } from "react";

const BLEND_MODES = [
  "normal",
  "screen",
  "multiply",
  "overlay",
  "soft-light",
  "hard-light",
  "color-dodge",
  "lighten",
  "darken",
  "difference",
  "exclusion",
  "luminosity",
] as const;

export default function EnergyRipples({ anchorId }: { anchorId: string }) {
  const [center, setCenter] = useState<{ x: number; y: number } | null>(null);

  const updatePosition = useCallback(() => {
    const el = document.getElementById(anchorId);
    if (!el) return;
    const rect = el.getBoundingClientRect();
    setCenter({
      x: rect.left + rect.width / 2 + window.scrollX,
      y: rect.top + rect.height / 2 + window.scrollY,
    });
  }, [anchorId]);

  useEffect(() => {
    updatePosition();
    window.addEventListener("resize", updatePosition);
    window.addEventListener("scroll", updatePosition);
    return () => {
      window.removeEventListener("resize", updatePosition);
      window.removeEventListener("scroll", updatePosition);
    };
  }, [updatePosition]);

  const p = useDialKit("Ripples", {
    count: [3, 1, 12, 1],
    duration: [4.5, 1, 20, 0.5],
    maxRadius: [1200, 200, 3000, 50],
    startOpacity: [0.06, 0.01, 1, 0.01],
    endOpacity: [0, 0, 0.5, 0.01],
    startStroke: [120, 0.5, 120, 0.5],
    endStroke: [0, 0, 30, 0.5],
    blur: [7, 0, 200, 1],
    blendMode: [6, 0, BLEND_MODES.length - 1, 1],
    color: "#0FFF88",
  });

  const blendMode = BLEND_MODES[p.blendMode] ?? "normal";

  if (!center) return null;

  return (
    <div
      style={{
        position: "absolute",
        inset: 0,
        overflow: "visible",
        pointerEvents: "none",
        zIndex: 0,
      }}
    >
      <svg
        style={{
          position: "absolute",
          left: center.x - p.maxRadius,
          top: center.y - p.maxRadius,
          width: p.maxRadius * 2,
          height: p.maxRadius * 2,
          filter: p.blur > 0 ? `blur(${p.blur}px)` : undefined,
          mixBlendMode: blendMode,
        }}
        viewBox={`0 0 ${p.maxRadius * 2} ${p.maxRadius * 2}`}
        fill="none"
      >
        {Array.from({ length: p.count }).map((_, i) => (
          <motion.circle
            key={`${p.count}-${i}`}
            cx={p.maxRadius}
            cy={p.maxRadius}
            r={0}
            stroke={p.color}
            fill="none"
            initial={{ r: 0, opacity: 0 }}
            animate={{
              r: [0, 0, p.maxRadius],
              opacity: [0, p.startOpacity, p.endOpacity],
              strokeWidth: [p.startStroke, p.startStroke, p.endStroke],
            }}
            transition={{
              duration: p.duration,
              repeat: Infinity,
              delay: i * (p.duration / p.count),
              ease: "easeOut",
              times: [0, 0.03, 1],
            }}
          />
        ))}
      </svg>
    </div>
  );
}
