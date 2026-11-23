import { Policy } from "@/components/marketing/policy";
import { siteMetadata } from "@/lib/site-metadata";

export const metadata = siteMetadata("en", "terms");

export default function Page() {
  return <Policy locale="en" page="terms" />;
}
