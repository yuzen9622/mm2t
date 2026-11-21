import { Guide } from "@/components/marketing/guide";
import { Pricing } from "@/components/marketing/pricing";
import { siteMetadata } from "@/lib/site-metadata";

export const metadata = siteMetadata("zh", "pricing");

export default function Page() {
  return <Guide locale="zh" page="pricing"><Pricing /></Guide>;
}
