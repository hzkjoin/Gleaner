import Foundation

/// What the message record is and isn't, for every prompt that reads it: so the model reads
/// it right, guesses only where the record supports it, and says when it can't tell.
public enum RecordNote {
    public static let text = """
    关于消息记录：
    - 记录来自通知，只有别人发来的消息；用户自己在微信等应用里发的话不在记录里，只有标"我:"的才是用户说的
    - 群聊每行是"发送人: 内容"；私聊每行前面是对方的名字，都是对方说的
    - "某人在群聊中@了你"只说明有人 @ 了用户，具体说了什么看不到
    - 图片、语音、视频、表情、文件只记作[图片][文件]之类，看不到内容
    - 用户正开着某个应用时它不发通知，那段消息可能缺；撤回的消息、静音的群也可能没有
    - 时间是收到通知的时间
    推测的原则：可以结合前后消息合理推测，推测时用"可能""看起来"；记录里没有的事不要编，看不出来就直说看不出来，不要把推测说成事实。
    """
}
