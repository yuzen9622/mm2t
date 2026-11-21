import { Changelog } from "@/components/marketing/changelog";
import { siteMetadata } from "@/lib/site-metadata";

export const metadata = siteMetadata("zh", "changelog");

export default function Page() {
  return <Changelog locale="zh" />;
}
