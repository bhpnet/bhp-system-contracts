yarn build
cd dist
git init
git add .
git commit -m "first commit"
git branch -M web
git remote add origin https://github.com/bhpnet/bhp-system-contracts.git
git push -u -f origin web
cd ..
rm -rf dist