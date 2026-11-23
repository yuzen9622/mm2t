import { Policy } from "@/components/marketing/policy";
import { siteMetadata } from "@/lib/site-metadata";

export const metadata = siteMetadata("en", "privacy");

export default function Page() {
  return <Policy locale="en" page="privacy" />;
}
