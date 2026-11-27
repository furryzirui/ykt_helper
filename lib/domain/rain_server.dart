/// The official Rain Classroom deployments supported by the mobile protocol.
enum RainServer {
  standard('www.yuketang.cn', '雨课堂'),
  hetang('pro.yuketang.cn', '荷塘雨课堂'),
  changjiang('changjiang.yuketang.cn', '长江雨课堂'),
  huanghe('huanghe.yuketang.cn', '黄河雨课堂');

  final String host, label;
  const RainServer(this.host, this.label);

  Uri get origin => Uri.https(host);
  Uri get websocketUri => Uri(scheme: 'wss', host: host, path: '/wsapp/');

  static RainServer fromName(String? name) => values.firstWhere(
    (server) => server.name == name,
    orElse: () => standard,
  );
}
