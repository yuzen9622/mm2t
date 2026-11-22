import {
  IconBook2,
  IconBrandGithub,
  IconCalendarEvent,
  IconCheck,
  IconChevronLeft,
  IconChevronRight,
  IconCopy,
  IconDots,
  IconDownload,
  IconExternalLink,
  IconFileText,
  IconFolder,
  IconHelpCircle,
  IconHome,
  IconInfoCircle,
  IconKey,
  IconMessages,
  IconMicrophone,
  IconPencil,
  IconPlayerPauseFilled,
  IconPlayerPlay,
  IconPlayerPlayFilled,
  IconPlus,
  IconSearch,
  IconSettings,
  IconShieldCheck,
  IconSparkles,
  IconStar,
  IconTrash,
  IconUpload,
  IconUsers,
  IconVideo,
  IconX,
} from "@tabler/icons-react";
import type { CSSProperties } from "react";
import { cn } from "@/lib/utils";

const icons = {
  arrow: IconChevronRight,
  diagonal: IconExternalLink,
  play: IconPlayerPlay,
  pause: IconPlayerPauseFilled,
  download: IconDownload,
  mic: IconMicrophone,
  file: IconFileText,
  users: IconUsers,
  home: IconHome,
  settings: IconSettings,
  book: IconBook2,
  check: IconCheck,
  chevron: IconChevronRight,
  close: IconX,
  shield: IconShieldCheck,
  lock: IconKey,
  laptop: IconSettings,
  cloud: IconUpload,
  sparkles: IconSparkles,
  calendar: IconCalendarEvent,
  github: IconBrandGithub,
  star: IconStar,
  menu: IconDots,
  messages: IconMessages,
  folder: IconFolder,
  help: IconHelpCircle,
  info: IconInfoCircle,
  search: IconSearch,
  pencil: IconPencil,
  copy: IconCopy,
  upload: IconUpload,
  trash: IconTrash,
  plus: IconPlus,
  back: IconChevronLeft,
  playFilled: IconPlayerPlayFilled,
  key: IconKey,
  video: IconVideo,
} as const;
export type IconName = keyof typeof icons;
export function Icon({
  name,
  size = 20,
  className,
  style,
}: {
  name: IconName;
  size?: number;
  className?: string;
  style?: CSSProperties;
}) {
  const Glyph = icons[name];
  return (
    <Glyph
      aria-hidden="true"
      focusable="false"
      size={size}
      className={cn("inline-block shrink-0", className)}
      style={style}
    />
  );
}
