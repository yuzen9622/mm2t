import { Guide } from "@/components/marketing/guide";
import { siteMetadata } from "@/lib/site-metadata";

export const metadata = siteMetadata("en", "models");

export default function Page() {
  return <Guide locale="en" page="models" />;
}
