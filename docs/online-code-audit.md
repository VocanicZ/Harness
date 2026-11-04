# An online code audit of the public Harness repo (optional)

This is a one-time setup for the repo **owner**: a free hosted code-quality service that reads the public
`VocanicZ/Harness` repo and publishes bugs, vulnerabilities, smells and duplication on its own dashboard.

**It is not a gate.** Nothing in Harness reads it, waits for it or depends on it: not the fleet, not
`test/run.sh`, not a lane's merge step, not the benchmark. Harness repos run no GitHub CI by design, and an
online audit does not change that: the services below analyse the repo from their own side after a push, and
a red or missing result blocks nothing. Skip this page and nothing changes.

It is separate from the benchmark's own, local, optional quality scan (`bench/quality.py`, SonarQube Community
in Docker, see [bench/README.md](../bench/README.md#code-quality-optional)): that one scores the code an arm
wrote; this one is a standing audit of Harness itself.

All three services are free for public repositories, use GitHub sign-in (no separate account or password), and
need no change to the repo. Pick one; they do not need each other. Their sites and plans change, so follow the
service's own current screens where they differ from the steps here.

## SonarQube Cloud

1. Open <https://sonarcloud.io> and choose **Log in with GitHub**; approve the GitHub authorisation.
2. **Import an organization from GitHub** and choose the GitHub account or organization that owns `Harness`.
   When GitHub asks which repositories the SonarQube Cloud app may access, choose **Only select repositories**
   and pick `VocanicZ/Harness` alone.
3. Choose the **Free** plan (public repositories only), then **Analyze new project** and select `Harness`.
4. Pick the analysis method **Automatic Analysis** (SonarQube Cloud analyses on every push from its side; no CI
   job, no token, no file added to the repo). Where a language is not covered by automatic analysis, leave it
   unanalysed rather than adding CI.
5. The project dashboard shows bugs, vulnerabilities, code smells, the maintainability rating, duplication and
   coverage. The project badge (project **Information**) can go in the README if the owner wants one.

## Codacy

1. Open <https://www.codacy.com> and **Sign up with GitHub**; approve the authorisation.
2. **Add repository** and choose `VocanicZ/Harness` (grant the Codacy app access to that one repository only).
3. Codacy analyses on its own after the add and on later pushes; the repository dashboard shows issues,
   complexity, duplication and a grade. Coverage needs a CI upload and stays empty here.

## DeepSource

1. Open <https://deepsource.com> and **Sign up with GitHub**; approve the authorisation.
2. **Activate** the `VocanicZ/Harness` repository (grant the DeepSource app that one repository only).
3. DeepSource wants a `.deepsource.toml` in the repo to choose analyzers; it can open the pull request that adds
   it. That file is configuration for the service, not a check: review the PR, and merge it only if you want
   DeepSource to analyse the repo.

## Turning it off again

Revoke the service's GitHub app (GitHub → Settings → Applications) or delete the project on the service's side.
Nothing in this repo refers to it, so nothing else needs to change.
