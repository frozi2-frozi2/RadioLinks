# RadioLinks

Текущая версия приложения: **1.0.0**, сборка **1**. Версия меняется вручную в `RadioLinks/build.sh`, номер сборки увеличивается после каждой успешной сборки и записывается в `RadioLinks/BuildNumber` и `Info.plist`.

Текущая версия: **1.0.0**. Номер сборки автоматически увеличивается при каждой успешной сборке; версия и номер сборки записываются в `Info.plist` приложения.

Небольшое приложение для фонового воспроизведения прямых интернет-радиопотоков на macOS.

В репозитории размещены исходный код и два архива:

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
