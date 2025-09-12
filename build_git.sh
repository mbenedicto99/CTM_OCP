git add .
git commit -m "init"
git branch -M main


# se não tiver o gh instalado, instale pelo gerenciador da sua distro
gh auth login -h github.com -p https -w    # faça login com o PAT (escopo: repo)
gh auth setup-git                          # integra o gh ao Git (credential helper)

git remote add origin https://github.com/mbenedicto99/AI_O11y_Custos.git 2>/dev/null || \
git remote set-url origin https://github.com/mbenedicto99/WLASAAS_OCP

git push -u origin main

