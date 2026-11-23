import type { Metadata } from "next";
import { AccountConsole } from "@/components/account/console";

export const metadata: Metadata = {
  title: "Account · mm2t",
  robots: { index: false },
  referrer: "no-referrer",
};

export default function AccountPage() {
  return <AccountConsole locale="en" />;
}
