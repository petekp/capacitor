import * as React from "react";
import { motion } from "motion/react";
import { Button, buttonVariants } from "./button";
import { springs } from "@/lib/motion";
import { cn } from "@/lib/utils";
import type { VariantProps } from "class-variance-authority";

type MotionButtonProps = React.ComponentProps<"button"> &
  VariantProps<typeof buttonVariants> & {
    asChild?: boolean;
  };

const MotionButton = React.forwardRef<HTMLButtonElement, MotionButtonProps>(
  ({ className, children, ...props }, ref) => {
    return (
      <motion.div
        whileHover={{ scale: 1.02 }}
        whileTap={{ scale: 0.97 }}
        transition={springs.snappy}
        className="inline-block"
      >
        <Button ref={ref} className={cn(className)} {...props}>
          {children}
        </Button>
      </motion.div>
    );
  }
);

MotionButton.displayName = "MotionButton";

export { MotionButton };
