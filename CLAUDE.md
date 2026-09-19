只修改 lib/ 和 spec/ 下的文件。不要修改 pgmoon，T1 中涉及 pgmoon 的改动跳过，记入文档末尾"执行中发现"。

禁止删除、注释或跳过任何测试用例（pending、skip、TAP SKIP 均不允许）。禁止修改 spec/review_spec.lua 中已有断言的语义。

仅 T4 的整数渲染变化和 T9 的 NULL 占位变化允许修改 spec/bug_spec.lua、spec/model_spec.lua 中的既有断言，每改一条在提交信息里写明用例名和改动前后的期望值。其它情况测试不通过一律改实现代码。

禁止调整测试参数绕过问题，特别是 B1 用例的 QUERY_TIMEOUT 和 POOL_NAME。

review_spec 中修改数据的用例必须在用例内恢复原状，或使用独立表和独立 POOL_NAME。

每完成一项任务，在 docs/orm-review.md 对应小节标记完成，附改动文件和测试命令完整输出，单独提交一次，提交信息含任务编号。

发现文档未列出的新问题，追加到文档末尾"执行中发现"一节，不要直接改。
