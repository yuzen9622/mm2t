import type { NextConfig } from "next";

const nextConfig: NextConfig = {
  output: "export",
  webpack(config) {
    config.module.rules.push({ test: /(?:CHANGELOG|(?:TERMS|PRIVACY|REFUNDS)\.(?:zh|en))\.md$/, type: "asset/source" });
    return config;
  },
  experimental: { globalNotFound: true },
  images: { unoptimized: true },
  trailingSlash: true,
  poweredByHeader: false,
};

export default nextConfig;
