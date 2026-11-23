import { Policy } from "@/components/marketing/policy";
import { siteMetadata } from "@/lib/site-metadata";

export const metadata = siteMetadata("zh", "terms");

export default function Page() {
  return <Policy locale="zh" page="terms" />;
}
