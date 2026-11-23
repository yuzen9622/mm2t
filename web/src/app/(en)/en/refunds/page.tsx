import { Policy } from "@/components/marketing/policy";
import { siteMetadata } from "@/lib/site-metadata";

export const metadata = siteMetadata("en", "refunds");

export default function Page() {
  return <Policy locale="en" page="refunds" />;
}
