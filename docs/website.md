# Publishing spedito.io

The product website is a framework-free static site in `Website/`. Cloudflare
Pages publishes it directly from the GitHub repository and creates a preview
deployment for non-production branches.

## One-time Cloudflare Pages setup

Complete this after the GitHub repository has been renamed to `spedito`:

1. In Cloudflare, open **Workers and Pages**, create a Pages application, and
   connect the `cristianrgreco/spedito` GitHub repository.
2. Use `spedito` as the project name and `main` as the production branch.
3. Choose no framework preset. Set the root directory to `Website`, the build
   command to `exit 0`, and the build output directory to `.`.
4. Deploy once and verify the generated `pages.dev` address.
5. Add both `spedito.io` and `www.spedito.io` under **Custom domains**. The apex
   domain requires the domain to use Cloudflare nameservers.
6. Make `spedito.io` canonical and add a permanent Cloudflare redirect from
   `www.spedito.io/*` to `https://spedito.io/$1`.

After setup, every push to `main` publishes production and other branches can
receive preview deployments. The repository's `Website/_headers` file supplies
the production security headers.
