"use client";

import { useEffect, useRef, useState, useCallback } from "react";


export default function FeatureGlow({ targetId }: { targetId: string }) {
  const [opacities, setOpacities] = useState<number[]>([]);
  const rafRef = useRef<number>(0);

  const update = useCallback(() => {
    const grid = document.getElementById(targetId);
    if (!grid) {
      rafRef.current = requestAnimationFrame(update);
      return;
    }

    const children = grid.children;
    const vh = window.innerHeight;
    const newOpacities: number[] = [];

    for (let i = 0; i < children.length; i++) {
      const rect = children[i].getBoundingClientRect();
      const progress = (vh - rect.top) / (vh + rect.height);

      let o = 0;
      if (progress <= 0.1) {
        o = 0;
      } else if (progress <= 0.25) {
        o = (progress - 0.1) / 0.15;
      } else if (progress <= 0.75) {
        o = 1;
      } else if (progress <= 0.9) {
        o = 1 - (progress - 0.75) / 0.15;
      }

      newOpacities.push(Math.max(0, Math.min(1, o)));
    }

    setOpacities(newOpacities);
    rafRef.current = requestAnimationFrame(update);
  }, [targetId]);

  useEffect(() => {
    rafRef.current = requestAnimationFrame(update);
    return () => cancelAnimationFrame(rafRef.current);
  }, [update]);

  // Inject per-tile CSS custom properties for glow opacity
  useEffect(() => {
    const grid = document.getElementById(targetId);
    if (!grid) return;

    for (let i = 0; i < grid.children.length; i++) {
      const child = grid.children[i] as HTMLElement;
      const opacity = opacities[i] ?? 0;
      child.style.setProperty("--glow-opacity", String(opacity));

      // Map scroll progress to border gradient angle (0deg → 240deg)
      const rect = child.getBoundingClientRect();
      const vh = window.innerHeight;
      const progress = (vh - rect.top) / (vh + rect.height);
      const angle = progress * 240;
      child.style.setProperty("--tile-border-angle", `${angle}deg`);
    }
  }, [opacities, targetId]);

  return null;
}
