import { format } from "sql-formatter";

process.stdin.setEncoding("utf8");

process.stdin.on("data", function (data) {
  // 当有输入时触发该事件
  const s = data.replaceAll(
    /```sql\n(.+?)\n```/g,
    (e) => "```sql\n" + format(e.slice(6, -4), { language: "postgresql" }) + "\n```"
  );
  console.log(s);
});

process.stdin.on("end", function () {
  // 输入结束时触发该事件
});
