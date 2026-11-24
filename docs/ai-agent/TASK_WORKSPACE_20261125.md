# Live task workspace — GSD

## Source and ownership

- Base: 6bd91d6a36155bd73ab71a428e69642b5989d842.
- Writer: feat/gsd-task-visualization-20261125 in an isolated Oracle worktree.
- Shared renderer: original TaskVisualizationKit SwiftPM package, remote URL and revision in project.yml. The release coordinator updates the initial contract revision to its verified implementation revision before building.
- The app continues to use its current Hanlin SDK selection. No upstream vendor implementation is edited.

## Behavior

Workspace is reachable as the fifth compact tab and an iPad sidebar destination. The command palette and compact/regular navigation handoff recognize the destination. Graph, quadrant board, due-date timeline, dependency network and task table use the same TaskStore snapshot.

Open and create present the normal task editor. A Saved reference opens the existing return-to-matrix editor. Completion, quadrant movement, due dates and dependency links call canonical TaskStore methods through a small ID-resolving bridge. The view displays action errors from the shared kit.

The show_task_workspace Hanlin tool is read-only. It validates presentation mode and explicit task IDs. Omitting IDs follows all current matrix tasks; passing IDs limits the view to them and their transitive prerequisites. Saved prerequisites remain visible, read-only and blocking. Recurrence lineage is not treated as hierarchy. Deleted selected tasks and missing prerequisites are explained in the UI.

The assistant embeds the same live workspace after a successful tool result and can expand it. An assistant toolbar entry also opens the workspace without a model request. Human interactions use the task store; AI writes continue to require the existing host approval.

No additional database, network account, cloud schema, production fixture or workflow status is introduced. View state is presentation state only.

## Validation ownership

The implementation lane performed static source inspection and git diff --check. It did not run compilation, package tests, simulator tests or release operations. Those gates belong to the coordinator's single Mac runner.

Focused package tests:
- GSDTaskWorkspaceTests: prerequisite closure (including Saved), recurrence exclusion, live all-task selection, invalid inputs, real stored mutations, cycle rejection, saved/deleted refusal, and read-only presentation tool.
- GSDHanlinAgentTests: expanded 23-tool catalog still contains 14 write tools.
- ChatGPTPlanContractTests: all 23 tools remain present through the original plan adapter.

Native acceptance:
GSDScreenshots / GSDTaskWorkspaceUITests /
testWorkspaceCompletionPropagatesAcrossViewsAndOpensCanonicalEditor

Run with GSD_TEST_LANGUAGE=en and he on the designated iPad/iPhone destinations. The test uses the existing isolated --demo-seed store, completes a seeded prerequisite through the real workspace, observes the same completion in another view, opens the existing task editor and checks its actual task title. Its screenshots are attached to the xcresult. It does not claim a persistent production account, physical-device acceptance, live AI inference or cloud synchronization.

The package mutation tests re-read the canonical repository after actions. Existing TaskStore and sync persistence receipts remain the authority for unchanged database and queue implementations.

## Release handoff

Regenerate the project with XcodeGen; do not hand-edit generated plist/pbxproj. Refresh and merge relevant accepted integration changes before building, allocate the release build number, resolve the final shared package revision and retain its upstream notices. Compile and run required focused/native checks before signed archive, export, upload and Apple processing. Record actual receipts in the Asana parent and milestone tasks.
