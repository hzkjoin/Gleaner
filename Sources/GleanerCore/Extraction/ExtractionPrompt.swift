import Foundation

/// Prompt and output schema used to turn notifications into action items.
enum ExtractionPrompt {
    static func system(userNames: [String], irrelevantExamples: [String] = []) -> String {
        base(userNames: userNames) + examplesSection(irrelevantExamples)
    }

    /// Items the user marked "不相关", so the model can avoid similar ones.
    static func examplesSection(_ examples: [String]) -> String {
        guard !examples.isEmpty else { return "" }
        let lines = examples.map { "- \($0)" }.joined(separator: "\n")
        return "\n\n用户曾把下面这些事项标记为【不相关】，类似的通知不要输出：\n\(lines)"
    }

    private static func base(userNames: [String]) -> String {
        let names = userNames.isEmpty ? "（未设置）" : userNames.joined(separator: "、")
        return """
        你是用户的个人助理。下面是用户 Mac 上最近收到的一批通知（来自微信、企业微信、邮件、短信等应用）。
        请找出其中【需要用户本人采取行动或值得用户关注】的事项。用户的称呼：\(names)。

        通知里的标记：【@我】表示消息 @ 了用户；【@所有人】表示 @ 了全体成员；
        【群消息未@人】表示群里没有 @ 任何人的消息，这类消息只能作为 notice 输出。
        群聊通知的标题是群名，正文是"发送人: 内容"；私聊通知的标题是对方名字。

        需要输出的情况：
        - 私聊里有人向用户提问、请求或催促
        - 带【@我】或【@所有人】的群消息里，有需要用户回应或处理的事
        - 需要用户审批、确认、填写、付款
        - 打卡异常、支付失败、账号安全这类需要用户处理的提醒
        - 有截止时间的任务、会议或日程邀请
        - 验证码：summary 写成"验证码 123456（服务名）"，数字照原文抄写；账单、月结单、安全提醒等邮件只是提到验证码或一次性密码的，不算验证码
        - 与用户本人有关的动态：外卖或快递送达、订单和行程变化、到账或扣款（作为 notice）
        - 带【群消息未@人】的群消息：只要不是纯闲聊、寒暄、表情，都作为 notice 输出，同一个群合并成一条

        不要输出的情况：
        - 纯闲聊、表情，"好的""收到""明白""谢谢"之类的确认或寒暄
        - 新闻资讯、公众号文章、营销推广、优惠活动

        规则：
        - 拿不准是否需要处理时，作为 notice 输出
        - 同一件事的多条通知合并成一条，sources 列出所有相关的通知编号
        - summary 不超过 20 个字：需要处理的事以动词开头说明要做什么；notice 直接概括内容
        - due 写截止时间（如"今天 18:00""周五前"），没有则为空字符串
        - priority 取 high、medium、low 之一
        - kind 取以下之一：
          reply：有人在等用户回复
          task：需要用户去做的事（审批、提交、填写、付款、参会）
          code：验证码
          alert：异常或安全提醒（打卡异常、支付失败、异地登录）
          notice：值得用户知道、但不必马上处理的事，priority 用 low

        只输出 JSON，格式为：
        {"actions":[{"sources":[1],"summary":"...","due":"","priority":"medium","kind":"reply"}]}
        没有需要处理的事项时输出 {"actions":[]}
        """
    }

    static func user(
        notifications: [(note: AppNotification, addressee: MentionAnalyzer.Addressee)],
        now: Date,
        appName: (String) -> String
    ) -> String {
        let header = DateFormatter()
        header.locale = Locale(identifier: "zh_CN")
        header.dateFormat = "yyyy-MM-dd HH:mm EEEE"
        let stamp = DateFormatter()
        stamp.dateFormat = "MM-dd HH:mm"

        var lines = ["当前时间：\(header.string(from: now))", "", "通知列表："]
        for (index, entry) in notifications.enumerated() {
            let note = entry.note
            var title = note.title
            if !note.subtitle.isEmpty { title += " / \(note.subtitle)" }
            let tag: String
            switch entry.addressee {
            case .user: tag = "【@我】"
            case .everyone: tag = "【@所有人】"
            case .nobodyInGroup: tag = "【群消息未@人】"
            case .others, .unspecified: tag = ""
            }
            let body = note.body.replacingOccurrences(of: "\n", with: " ")
            lines.append("[\(index + 1)] \(stamp.string(from: note.date)) | \(appName(note.appID)) | \(title) | \(tag)\(body)")
        }
        return lines.joined(separator: "\n")
    }

    static let schema = """
    {
      "type": "object",
      "additionalProperties": false,
      "required": ["actions"],
      "properties": {
        "actions": {
          "type": "array",
          "items": {
            "type": "object",
            "additionalProperties": false,
            "required": ["sources", "summary", "due", "priority", "kind"],
            "properties": {
              "sources": {"type": "array", "items": {"type": "integer"}},
              "summary": {"type": "string"},
              "due": {"type": "string"},
              "priority": {"type": "string", "enum": ["high", "medium", "low"]},
              "kind": {"type": "string", "enum": ["reply", "task", "code", "alert", "notice"]}
            }
          }
        }
      }
    }
    """
}
