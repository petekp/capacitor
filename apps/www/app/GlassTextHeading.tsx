"use client";

import { useRef, useEffect, type ReactNode } from "react";
import { useMotionValue, useSpring, useMotionValueEvent } from "motion/react";
import { useDialKit } from "dialkit";

const MOUSE_SPRING = { stiffness: 200, damping: 30, mass: 0.3 };

export default function GlassTextHeading({
  children,
  className,
}: {
  children: ReactNode;
  className?: string;
}) {
  const filterId = "glass-text-hero";
  const containerRef = useRef<HTMLDivElement>(null);
  const diffPointLightRef = useRef<SVGFEPointLightElement>(null);
  const specPointLightRef = useRef<SVGFEPointLightElement>(null);

  const mouseX = useMotionValue(0);
  const mouseY = useMotionValue(0);
  const sx = useSpring(mouseX, MOUSE_SPRING);
  const sy = useSpring(mouseY, MOUSE_SPRING);

  const p = useDialKit("Glass Text", {
    blurStdDev: [1, 0, 8, 0.1],
    diffSurfaceScale: [0, 0, 30, 0.5],
    diffConstant: [1.85, 0, 3, 0.05],
    diffLightZ: [40, 0, 800, 10],
    specSurfaceScale: [11, 0, 30, 0.5],
    specConstant: [5, 0, 5, 0.1],
    specExponent: [21, 1, 128, 1],
    specLightZ: [50, 0, 800, 10],
    diffOpacity: [0.7, 0, 1, 0.05],
    specOpacity: [0.6, 0, 1, 0.05],
  });

  useMotionValueEvent(sx, "change", (v) => {
    diffPointLightRef.current?.setAttribute("x", String(v));
    specPointLightRef.current?.setAttribute("x", String(v));
  });
  useMotionValueEvent(sy, "change", (v) => {
    diffPointLightRef.current?.setAttribute("y", String(v));
    specPointLightRef.current?.setAttribute("y", String(v));
  });

  useEffect(() => {
    const onMove = (e: MouseEvent) => {
      const el = containerRef.current;
      if (!el) return;
      const rect = el.getBoundingClientRect();
      mouseX.set(e.clientX - rect.left);
      mouseY.set(e.clientY - rect.top);
    };
    window.addEventListener("mousemove", onMove);
    return () => window.removeEventListener("mousemove", onMove);
  }, [mouseX, mouseY]);

  return (
    <div ref={containerRef} className={className} style={{ position: "relative" }}>
      <svg
        aria-hidden="true"
        style={{ position: "absolute", width: 0, height: 0 }}
      >
        <defs>
          <filter
            id={filterId}
            x="-10%"
            y="-10%"
            width="120%"
            height="120%"
            colorInterpolationFilters="sRGB"
          >
            <feGaussianBlur
              in="SourceAlpha"
              stdDeviation={p.blurStdDev}
              result="blur"
            />
            <feDiffuseLighting
              in="blur"
              surfaceScale={p.diffSurfaceScale}
              diffuseConstant={p.diffConstant}
              result="diffuse"
            >
              <fePointLight ref={diffPointLightRef} x={0} y={0} z={p.diffLightZ} />
            </feDiffuseLighting>
            <feSpecularLighting
              in="blur"
              surfaceScale={p.specSurfaceScale}
              specularConstant={p.specConstant}
              specularExponent={p.specExponent}
              result="specular"
            >
              <fePointLight ref={specPointLightRef} x={0} y={0} z={p.specLightZ} />
            </feSpecularLighting>
            <feComposite
              in="specular"
              in2="SourceAlpha"
              operator="in"
              result="specClip"
            />
            <feComposite
              in="diffuse"
              in2="SourceAlpha"
              operator="in"
              result="diffClip"
            />
            <feColorMatrix
              in="diffClip"
              type="matrix"
              values={`1 0 0 0 0 0 1 0 0 0 0 0 1 0 0 0 0 0 ${p.diffOpacity} 0`}
              result="diffFade"
            />
            <feColorMatrix
              in="specClip"
              type="matrix"
              values={`1 0 0 0 0 0 1 0 0 0 0 0 1 0 0 0 0 0 ${p.specOpacity} 0`}
              result="specFade"
            />
            <feMerge>
              <feMergeNode in="diffFade" />
              <feMergeNode in="specFade" />
            </feMerge>
          </filter>
        </defs>
      </svg>

      {/* Base text — invisible, just for layout */}
      <span style={{ color: "transparent" }}>
        {children}
      </span>

      {/* Lighting overlay */}
      <span
        aria-hidden="true"
        style={{
          position: "absolute",
          inset: 0,
          filter: `url(#${filterId})`,
          color: "white",
          pointerEvents: "none",
        }}
      >
        {children}
      </span>
    </div>
  );
}
