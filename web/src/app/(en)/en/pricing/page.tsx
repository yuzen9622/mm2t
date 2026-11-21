import { Guide } from "@/components/marketing/guide";
import { Pricing } from "@/components/marketing/pricing";
import { siteMetadata } from "@/lib/site-metadata";

export const metadata = siteMetadata("en", "pricing");

export default function Page() {
  return <Guide locale="en" page="pricing"><Pricing /></Guide>;
}
