# RadioLinks

Небольшое приложение для фонового воспроизведения прямых интернет-радиопотоков на macOS.

В приватном репозитории размещены исходный код и два архива:

- [RadioLinks-macOS.zip](https://github.com/frozi2-frozi2/RadioLinks/raw/refs/heads/main/RadioLinks-macOS.zip) — готовое приложение `RadioLinks.app`.
- [RadioLinks-source.zip](https://github.com/frozi2-frozi2/RadioLinks/raw/refs/heads/main/RadioLinks-source.zip) — полный архив исходников с ресурсами.

Скачайте архив приложения, распакуйте его и перенесите `RadioLinks.app` в папку «Программы» или на рабочий стол.

## Сборка из исходников

Распакуйте `RadioLinks-source.zip`, откройте папку `RadioLinks` и на Mac с Xcode Command Line Tools выполните:

```sh
bash build.sh
```

Скрипт соберёт приложение на уровень выше папки проекта.

Поддерживаются прямые HTTP/HTTPS URL радиопотоков и PLS/M3U плейлисты. Данные о станции и композиции отображаются, если их передаёт поток или API станции.
