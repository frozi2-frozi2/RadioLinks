# RadioLinks

Небольшое приложение для фонового воспроизведения прямых интернет-радиопотоков на macOS.

В репозитории находятся исходный код и два архива в корне:

- [RadioLinks-macOS.zip](https://github.com/frozi2-frozi2/RadioLinks/raw/refs/heads/main/RadioLinks-macOS.zip) — готовое приложение `RadioLinks.app`.
- [RadioLinks-source.zip](https://github.com/frozi2-frozi2/RadioLinks/raw/refs/heads/main/RadioLinks-source.zip) — полный архив исходников с ресурсами.

Скачайте архив приложения, распакуйте его и перенесите `RadioLinks.app` в папку «Программы» или на рабочий стол. На другом Mac можно перенести весь пакет приложения.

## Сборка из исходников

На Mac с установленными Xcode Command Line Tools распакуйте `RadioLinks-source.zip`, откройте папку `RadioLinks` и выполните:

```sh
bash build.sh
```

Скрипт соберёт приложение на уровень выше папки проекта.

Поддерживаются прямые HTTP/HTTPS URL радиопотоков и PLS/M3U плейлисты. Данные о станции и композиции отображаются, если их передаёт поток или API станции.
