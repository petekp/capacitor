import type { Metadata } from "next";
import "./globals.css";
import DialProvider from "./DialProvider";

export const metadata: Metadata = {
  title: "Capacitor — A glanceable companion for Claude Code",
  description:
    "See what every Claude Code session is doing across all your projects. Live status, one-click terminal switching, and zero data collection. A native macOS app for Apple Silicon.",
  openGraph: {
    title: "Capacitor",
    description:
      "A native macOS companion that shows you what every Claude Code session is doing — across all your projects, in real time.",
    type: "website",
    siteName: "Capacitor",
  },
  twitter: {
    card: "summary",
    title: "Capacitor — A glanceable companion for Claude Code",
    description:
      "Live session status, one-click terminal switching, and zero data collection. Native macOS app for Claude Code.",
  },
};

export default function RootLayout({
  children,
}: Readonly<{
  children: React.ReactNode;
}>) {
  return (
    <html lang="en">
      <body>
        {children}
        <DialProvider />
      </body>
    </html>
  );
}
