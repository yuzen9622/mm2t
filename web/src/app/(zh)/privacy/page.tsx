import { Policy } from "@/components/marketing/policy";
import { siteMetadata } from "@/lib/site-metadata";

export const metadata = siteMetadata("zh", "privacy");

export default function Page() {
  return <Policy locale="zh" page="privacy" />;
}
