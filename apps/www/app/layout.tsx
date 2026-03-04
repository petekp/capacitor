import type { Metadata } from "next";
import "./globals.css";

export const metadata: Metadata = {
  title: "Capacitor — A glanceable companion for Claude Code",
  description:
    "Live session status, one-click terminal focus, and respect for your existing tools. A macOS companion for Claude Code power users.",
  openGraph: {
    title: "Capacitor",
    description: "A glanceable companion for Claude Code",
    type: "website",
  },
};

export default function RootLayout({
  children,
}: Readonly<{
  children: React.ReactNode;
}>) {
  return (
    <html lang="en">
      <body>{children}</body>
    </html>
  );
}
