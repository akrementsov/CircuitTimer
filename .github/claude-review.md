Review this pull request with the `superpowers:requesting-code-review` skill. Follow its procedure for dispatching the reviewer subagent, with these placeholders:

- `DESCRIPTION`: the pull request title and description given below;
- `PLAN_OR_REQUIREMENTS`: the pull request description, together with the rules in `AGENTS.md`, which the change must follow;
- `BASE_SHA` and `HEAD_SHA`: the commits given below.

Tell the reviewer that the repository is checked out at `HEAD_SHA` and that it should read whatever it needs to judge a change in context: callers, tests, neighbouring modules. A `file:line` reference is a line of the file at `HEAD_SHA`, not a line of the diff output: open the file to get it. Problems that SwiftLint already enforces are out of scope.

Nobody acts on the feedback in this session, so skip the skill's step of acting on it. Your whole reply becomes a pull request comment: start with the heading `## Claude review`, then give the reviewer's report unchanged, in GitHub Markdown, with no preamble.
