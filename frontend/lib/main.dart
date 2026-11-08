import 'dart:io';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show PlatformException;
import 'package:image_picker/image_picker.dart';
import 'analysis.dart';
import 'services/classifier.dart';
import 'services/history_store.dart';
import 'services/photo_input.dart';
import 'widgets/analysis_result.dart';

const forest = Color(0xFF174F3B);
const paper = Color(0xFFF6F7F2);
const ink = Color(0xFF20382D);

void main() => runApp(const TomatoLensApp());

class TomatoLensApp extends StatelessWidget {
  const TomatoLensApp({super.key, this.classifier, this.history, this.photoInput});
  final Classifier? classifier;
  final HistoryStore? history;
  final PhotoInput? photoInput;
  @override
  Widget build(BuildContext context) => MaterialApp(
    title: 'TomatoLens',
    debugShowCheckedModeBanner: false,
    theme: ThemeData(
      useMaterial3: true,
      scaffoldBackgroundColor: paper,
      colorScheme: ColorScheme.fromSeed(
        seedColor: forest,
        primary: forest,
        surface: Colors.white,
      ),
      appBarTheme: const AppBarTheme(
        backgroundColor: paper,
        foregroundColor: ink,
        elevation: 0,
      ),
      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(
          minimumSize: const Size(0, 52),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(16),
          ),
        ),
      ),
      inputDecorationTheme: const InputDecorationTheme(
        border: OutlineInputBorder(),
      ),
    ),
    home: HomeShell(
      classifier: classifier ?? LocalClassifier(),
      history: history ?? SqliteHistoryStore(),
      photoInput: photoInput ?? PhotoInput(),
    ),
  );
}

class HomeShell extends StatefulWidget {
  const HomeShell({
    super.key,
    required this.classifier,
    required this.history,
    required this.photoInput,
  });
  final Classifier classifier;
  final HistoryStore history;
  final PhotoInput photoInput;
  @override
  State<HomeShell> createState() => _HomeShellState();
}

class _HomeShellState extends State<HomeShell> {
  int _tab = 0;
  static const _pageSize = 20;
  bool _ready = false, _busy = false, _saving = false, _saved = false;
  bool _loadingModel = false, _loadingHistory = false, _hasMore = false;
  bool _preferencesReady = false, _changingPreferences = false, _deleting = false;
  int _historyRequest = 0;
  int? _savedCount;
  String? _analysisError;
  SavePreferences _preferences = const SavePreferences();
  String? _modelError, _historyError;
  String _version = '';
  Uint8List? _image;
  Analysis? _result;
  List<Analysis> _history = [];
  List<Analysis> _recent = [];
  String? _filter;
  bool get _canPick => _ready && !_busy && !_saving && !_deleting && !_changingPreferences;

  @override
  void initState() {
    super.initState();
    _initialize();
  }

  Future<void> _initialize() async {
    await Future.wait([_loadModel(), _refresh(), _loadPreferences()]);
    if (!mounted || !Platform.isAndroid || !_canPick) return;
    setState(() => _busy = true);
    try {
      final recovered = await widget.photoInput.recover();
      if (mounted && recovered != null) await _previewAndAnalyze(recovered);
    } on PhotoProblem catch (error) {
      _notice(error.message);
    } catch (_) {
      _notice('No se pudo recuperar la foto anterior. Puedes seleccionarla otra vez.');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _loadModel() async {
    if (_loadingModel) return;
    setState(() => _loadingModel = true);
    try {
      final version = await widget.classifier.load();
      if (!mounted) return;
      setState(() {
        _ready = true;
        _modelError = null;
        _version = version;
      });
    } catch (_) {
      if (mounted) {
        setState(() {
          _ready = false;
          _modelError = 'No se pudo abrir el modelo. Intenta cargarlo de nuevo.';
        });
      }
    } finally {
      if (mounted) setState(() => _loadingModel = false);
    }
  }

  Future<void> _loadPreferences() async {
    try {
      final value = await widget.history.preferences();
      if (mounted) {
        setState(() {
          _preferences = value;
          _preferencesReady = true;
        });
      }
    } catch (_) {
      _notice('No se pudieron leer las preferencias de guardado.');
    }
  }

  Future<void> _setPreferences(SavePreferences value) async {
    if (_changingPreferences || _saving || _busy) return;
    setState(() => _changingPreferences = true);
    try {
      await widget.history.setPreferences(value);
      if (mounted) setState(() => _preferences = value);
    } catch (_) {
      _notice('No se pudo guardar la preferencia. Inténtalo otra vez.');
    } finally {
      if (mounted) setState(() => _changingPreferences = false);
    }
  }

  Future<void> _refresh({bool append = false}) async {
    if (!mounted || (append && (_loadingHistory || !_hasMore))) return;
    final request = ++_historyRequest;
    final category = _filter;
    final after = append ? _history.last : null;
    setState(() {
      _loadingHistory = true;
      _historyError = null;
    });
    try {
      final rows = await widget.history.list(
        limit: _pageSize + 1,
        after: after,
        category: category,
      );
      final count = append ? _savedCount : await widget.history.count();
      final recent = append ? _recent : category == null
          ? rows.take(3).toList()
          : await widget.history.list(limit: 3);
      if (!mounted || request != _historyRequest) return;
      setState(() {
        _history = [if (append) ..._history, ...rows.take(_pageSize)];
        _hasMore = rows.length > _pageSize;
        _savedCount = count;
        _recent = recent;
      });
    } catch (_) {
      if (mounted && request == _historyRequest) {
        setState(() => _historyError = 'No se pudo cargar el historial local.');
      }
    } finally {
      if (mounted && request == _historyRequest) {
        setState(() => _loadingHistory = false);
      }
    }
  }

  void _changeFilter(String? category) {
    if (_filter == category) return;
    setState(() {
      _filter = category;
      _history = [];
      _hasMore = false;
    });
    _refresh();
  }

  @override
  void dispose() {
    widget.history.close();
    super.dispose();
  }

  void _notice(String text) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(text)));
  }

  Future<void> _pick(ImageSource source) async {
    if (!_canPick) return;
    setState(() => _busy = true);
    try {
      var chooseAgain = true;
      while (mounted && chooseAgain) {
        final picked = await widget.photoInput.pick(source);
        if (!mounted || picked == null) return;
        chooseAgain = await _previewAndAnalyze(picked);
      }
    } on PhotoProblem catch (error) {
      _notice(error.message);
    } on PlatformException catch (error) {
      final code = error.code.toLowerCase();
      _notice(code.contains('access') || code.contains('permission')
          ? 'No hay permiso para abrir la cámara o la galería. Revisa los ajustes de Android.'
          : 'No se pudo abrir la cámara o la galería. Prueba con la otra opción.');
    } on FileSystemException {
      _notice('No se pudo leer el archivo de la foto. Selecciona otra.');
    } catch (_) {
      _notice('No se pudo completar la selección. Inténtalo otra vez.');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<bool> _previewAndAnalyze(XFile picked) async {
    final bytes = await widget.photoInput.read(picked);
    if (!mounted) return false;
    final action = await showDialog<_PreviewAction>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Revisa la fotografía'),
        scrollable: true,
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Image.memory(bytes, height: 240, cacheWidth: 640, fit: BoxFit.contain),
            const SizedBox(height: 16),
            const Text('Usa una sola hoja de tomate, enfocada y bien iluminada.'),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancelar'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, _PreviewAction.change),
            child: const Text('Cambiar foto'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, _PreviewAction.analyze),
            child: const Text('Analizar hoja'),
          ),
        ],
      ),
    );
    if (!mounted || action == null) return false;
    if (action == _PreviewAction.change) return true;
    setState(() {
      _image = bytes;
      _result = null;
      _saved = false;
      _analysisError = null;
      _tab = 1;
    });
    try {
      final result = await widget.classifier.predict(bytes);
      if (!mounted) return false;
      setState(() => _result = result);
      if (_preferencesReady && _preferences.autoSave) await _save();
    } catch (_) {
      if (mounted) {
        setState(() => _analysisError =
            'El modelo no pudo analizar esta foto. Prueba con otra fotografía.');
      }
    }
    return false;
  }

  Future<void> _save() async {
    final result = _result;
    final bytes = _image;
    if (result == null ||
        bytes == null ||
        _saving ||
        _saved ||
        _deleting ||
        _changingPreferences ||
        !_preferencesReady) {
      return;
    }
    setState(() => _saving = true);
    try {
      await widget.history.save(result, _preferences.keepPhoto ? bytes : null);
      if (!mounted) return;
      if (_result?.id == result.id) setState(() => _saved = true);
      await _refresh();
      _notice('Análisis guardado en este dispositivo.');
    } catch (_) {
      _notice('No se pudo guardar. Comprueba el espacio disponible y vuelve a intentarlo.');
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<bool> _confirm(String title, String message) async =>
      await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: Text(title),
          content: Text(message),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('Cancelar'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('Eliminar'),
            ),
          ],
        ),
      ) ??
      false;
  Future<void> _delete(Analysis analysis) async {
    if (_saving || _deleting || _busy) return;
    if (!await _confirm(
      '¿Eliminar análisis?',
      'Se eliminarán el resultado y la fotografía guardada.',
    )) {
      return;
    }
    if (!mounted || _saving || _deleting || _busy) return;
    setState(() => _deleting = true);
    try {
      await widget.history.delete(analysis);
      if (mounted && _result?.id == analysis.id) setState(() => _saved = false);
      await _refresh();
    } catch (_) {
      _notice('No se pudo eliminar. Vuelve a intentarlo.');
    } finally {
      if (mounted) setState(() => _deleting = false);
    }
  }

  Future<void> _clear() async {
    if (_saving || _deleting || _busy) return;
    if (!await _confirm(
      '¿Vaciar historial?',
      'Esta acción elimina todos los análisis y sus fotografías locales.',
    )) {
      return;
    }
    if (!mounted || _saving || _deleting || _busy) return;
    setState(() => _deleting = true);
    try {
      await widget.history.clear();
      if (mounted) setState(() => _saved = false);
      await _refresh();
    } catch (_) {
      await _refresh();
      _notice('No se pudo completar el borrado. Puedes reintentarlo.');
    } finally {
      if (mounted) setState(() => _deleting = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final body = switch (_tab) {
      0 => _dashboard(),
      1 => _analysis(),
      2 => _historyPage(),
      _ => _guide(),
    };
    return Scaffold(
      appBar: AppBar(
        title: Row(
          children: [
            const _BrandMark(size: 40),
            const SizedBox(width: 8),
            const Expanded(
              child: Text(
                'TomatoLens',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontWeight: FontWeight.w800,
                  letterSpacing: -.6,
                ),
              ),
            ),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
              decoration: BoxDecoration(
                color: const Color(0xFFE5EDE4),
                borderRadius: BorderRadius.circular(30),
              ),
              child: const Row(
                children: [
                  Icon(Icons.wifi_off_rounded, size: 14),
                  SizedBox(width: 5),
                  Text('Local', style: TextStyle(fontSize: 12)),
                ],
              ),
            ),
          ],
        ),
      ),
      body: SafeArea(
        child: Align(
          alignment: Alignment.topCenter,
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 760),
            child: ListView(
              padding: const EdgeInsets.fromLTRB(20, 16, 20, 28),
              children: [
                if (_modelError != null)
                  _panel(
                    Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(_modelError!),
                        TextButton(
                          onPressed: _loadingModel ? null : _loadModel,
                          child: const Text('Reintentar carga'),
                        ),
                      ],
                    ),
                  ),
                ...body,
              ],
            ),
          ),
        ),
      ),
      bottomNavigationBar: NavigationBar(
        selectedIndex: _tab,
        onDestinationSelected: (i) => setState(() => _tab = i),
        destinations: const [
          NavigationDestination(
            icon: Icon(Icons.grid_view_outlined),
            selectedIcon: Icon(Icons.grid_view_rounded),
            label: 'Inicio',
          ),
          NavigationDestination(
            icon: Icon(Icons.add_a_photo_outlined),
            selectedIcon: Icon(Icons.add_a_photo),
            label: 'Analizar',
          ),
          NavigationDestination(
            icon: Icon(Icons.history_rounded),
            label: 'Historial',
          ),
          NavigationDestination(
            icon: Icon(Icons.menu_book_outlined),
            selectedIcon: Icon(Icons.menu_book),
            label: 'Guía',
          ),
        ],
      ),
    );
  }

  Widget _panel(Widget child, {Color color = Colors.white}) => Container(
    margin: const EdgeInsets.only(bottom: 16),
    padding: const EdgeInsets.all(20),
    decoration: BoxDecoration(
      color: color,
      borderRadius: BorderRadius.circular(24),
      border: Border.all(color: const Color(0xFFE3E8DF)),
    ),
    child: child,
  );
  Widget _heading(String title, String subtitle) => Padding(
    padding: const EdgeInsets.only(bottom: 22),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          title,
          style: const TextStyle(
            fontSize: 29,
            fontWeight: FontWeight.w800,
            color: ink,
            letterSpacing: -.9,
          ),
        ),
        const SizedBox(height: 6),
        Text(
          subtitle,
          style: const TextStyle(color: Color(0xFF647267), height: 1.5),
        ),
      ],
    ),
  );
  List<Widget> _dashboard() => [
    _heading(
      'Una mirada a tus hojas',
      'Observa, analiza y conserva tus resultados en un solo lugar.',
    ),
    _panel(
      Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Row(
            children: [
              DecoratedBox(
                decoration: BoxDecoration(
                  color: paper,
                  borderRadius: BorderRadius.all(Radius.circular(10)),
                ),
                child: Padding(
                  padding: EdgeInsets.all(4),
                  child: _BrandMark(size: 30),
                ),
              ),
              Spacer(),
              Text(
                'TOMATE · 3 CATEGORÍAS',
                style: TextStyle(
                  color: Color(0xFFCFE8B8),
                  fontSize: 11,
                  letterSpacing: 1.3,
                ),
              ),
            ],
          ),
          const SizedBox(height: 24),
          const Text(
            '¿Cómo se ve\ntu hoja hoy?',
            style: TextStyle(
              fontSize: 32,
              fontWeight: FontWeight.w700,
              color: Colors.white,
              height: 1.15,
            ),
          ),
          const SizedBox(height: 12),
          const Text(
            'Selecciona una fotografía y consulta la clasificación del modelo, sin conexión.',
            style: TextStyle(color: Color(0xFFDCE9DF), height: 1.5),
          ),
          const SizedBox(height: 22),
          FilledButton.icon(
            style: FilledButton.styleFrom(
              backgroundColor: const Color(0xFFD9EBBE),
              foregroundColor: forest,
            ),
            onPressed: () => setState(() => _tab = 1),
            icon: const Icon(Icons.arrow_forward_rounded),
            label: const Text('Comenzar análisis'),
          ),
        ],
      ),
      color: forest,
    ),
    Row(
      children: [
        Expanded(
          child: _metric(
            _savedCount?.toString() ?? '—',
            'Guardados',
            Icons.bookmark_border,
          ),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: _metric(
            _ready ? 'Listo' : _modelError == null ? 'Cargando' : 'No disponible',
            'Modelo local',
            Icons.memory_rounded,
          ),
        ),
      ],
    ),
    _section('Antes de tomar la foto'),
    _panel(
      const Column(
        children: [
          _Tip(
            icon: Icons.filter_center_focus,
            text: 'Una hoja por fotografía',
            detail: 'Acércate sin cortar sus bordes.',
          ),
          Divider(height: 28),
          _Tip(
            icon: Icons.wb_sunny_outlined,
            text: 'Luz clara y enfoque',
            detail: 'Evita sombras fuertes y desenfoque.',
          ),
        ],
      ),
    ),
    _section('Análisis recientes'),
    if (_historyError != null)
      _historyErrorPanel()
    else if (_savedCount == null)
      const LinearProgressIndicator()
    else if (_recent.isEmpty)
      _empty(
        'Tu historial comienza aquí',
        'Los análisis que guardes aparecerán en esta sección.',
        Icons.history,
      )
    else
      ..._recent.map(_historyTile),
    const Text(
      'Clasificación orientativa. Las puntuaciones del modelo no equivalen a una certeza diagnóstica.',
      style: TextStyle(fontSize: 12, color: Color(0xFF647267), height: 1.5),
    ),
  ];
  Widget _metric(String value, String caption, IconData icon) => _panel(
    Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Icon(icon, color: forest),
        const SizedBox(height: 12),
        Text(
          value,
          style: const TextStyle(
            fontSize: 25,
            fontWeight: FontWeight.w800,
            color: ink,
          ),
        ),
        Text(
          caption,
          style: const TextStyle(color: Color(0xFF647267), fontSize: 12),
        ),
      ],
    ),
  );
  Widget _section(String title) => Padding(
    padding: const EdgeInsets.only(top: 4, bottom: 12),
    child: Text(
      title,
      style: const TextStyle(
        fontSize: 18,
        fontWeight: FontWeight.w700,
        color: ink,
      ),
    ),
  );
  List<Widget> _analysis() => [
    _heading(
      'Analizar una hoja',
      'Fotografía individual de tomate · resultado en este dispositivo',
    ),
    if (_image != null)
      ClipRRect(
        borderRadius: BorderRadius.circular(24),
        child: Image.memory(
          _image!,
          height: 280,
          cacheWidth: 768,
          fit: BoxFit.contain,
          errorBuilder: (_, e, s) => const SizedBox(
            height: 150,
            child: Center(child: Text('No se pudo mostrar la imagen.')),
          ),
        ),
      )
    else
      _empty(
        'Elige tu fotografía',
        'Usa la cámara o selecciona una imagen de tu galería.',
        Icons.add_photo_alternate_outlined,
      ),
    const SizedBox(height: 18),
    Wrap(
      spacing: 12,
      runSpacing: 10,
      children: [
        FilledButton.icon(
          onPressed: _canPick ? () => _pick(ImageSource.camera) : null,
          icon: const Icon(Icons.camera_alt_outlined),
          label: const Text('Tomar foto'),
        ),
        OutlinedButton.icon(
          style: OutlinedButton.styleFrom(minimumSize: const Size(0, 52)),
          onPressed: _canPick ? () => _pick(ImageSource.gallery) : null,
          icon: const Icon(Icons.photo_library_outlined),
          label: const Text('Galería'),
        ),
      ],
    ),
    const SizedBox(height: 22),
    if (_busy)
      _panel(
        const Row(
          children: [
            SizedBox(
              width: 22,
              height: 22,
              child: CircularProgressIndicator(strokeWidth: 2),
            ),
            SizedBox(width: 16),
            Expanded(child: Text('Preparando imagen y analizando…')),
          ],
        ),
      ),
    if (_analysisError != null)
      _panel(Text(_analysisError!), color: const Color(0xFFF1EDDE)),
    if (_result != null) ...[
      _resultCard(_result!),
      FilledButton.icon(
        onPressed: _saving || _saved || _busy || _deleting || _changingPreferences || !_preferencesReady
            ? null
            : _save,
        icon: Icon(_saved ? Icons.check : Icons.bookmark_add_outlined),
        label: Text(
          _saved
              ? 'Guardado en historial'
              : _saving
              ? 'Guardando…'
              : 'Guardar análisis',
        ),
      ),
      const SizedBox(height: 12),
    ],
    _panel(
      const Text(
        'El modelo distingue hoja sana, tizón temprano y tizón tardío. Otras enfermedades, objetos o fotografías fuera de estas condiciones pueden producir resultados incorrectos.',
        style: TextStyle(height: 1.5, fontSize: 13),
      ),
      color: const Color(0xFFF1EDDE),
    ),
  ];
  Widget _resultCard(Analysis result) =>
      _panel(AnalysisResult(result: result, formatDate: _date));

  List<Widget> _historyPage() => [
    _heading(
      'Tu historial',
      'Fotografías y resultados guardados solo en este dispositivo.',
    ),
    Wrap(
      spacing: 8,
      runSpacing: 8,
      children: [
        ChoiceChip(label: const Text('Todas'), selected: _filter == null,
            onSelected: (_) => _changeFilter(null)),
        for (var i = 0; i < classKeys.length; i++)
          ChoiceChip(label: Text(classNames[i]), selected: _filter == classKeys[i],
              onSelected: (_) => _changeFilter(classKeys[i])),
        ChoiceChip(label: const Text('No concluyente'), selected: _filter == inconclusiveKey,
            onSelected: (_) => _changeFilter(inconclusiveKey)),
      ],
    ),
    const SizedBox(height: 18),
    if (_historyError != null)
      _historyErrorPanel()
    else if (_loadingHistory && _history.isEmpty)
      const LinearProgressIndicator()
    else if (_history.isEmpty)
      _empty(
        _filter == null ? 'Aún no hay análisis guardados' : 'Sin resultados en esta categoría',
        _filter == null ? 'Analiza una imagen y pulsa «Guardar análisis».' : 'Prueba con otro filtro.',
        Icons.bookmarks_outlined,
      )
    else
      ..._history.map(_historyTile),
    if (_hasMore && _historyError == null)
      OutlinedButton(
        onPressed: _loadingHistory ? null : () => _refresh(append: true),
        child: Text(_loadingHistory ? 'Cargando…' : 'Cargar más'),
      ),
    if ((_savedCount ?? 0) > 0)
      Align(
        alignment: Alignment.centerLeft,
        child: TextButton.icon(
          onPressed: _saving || _deleting || _busy ? null : _clear,
          icon: const Icon(Icons.delete_outline),
          label: const Text('Vaciar historial'),
        ),
      ),
  ];

  Widget _historyErrorPanel() => _panel(
    Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(_historyError!),
        TextButton(
          onPressed: () => _refresh(),
          child: const Text('Reintentar historial'),
        ),
      ],
    ),
  );
  Widget _historyTile(Analysis r) => Padding(
    padding: const EdgeInsets.only(bottom: 10),
    child: Material(
      color: Colors.white,
      borderRadius: BorderRadius.circular(18),
      child: ListTile(
        contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        leading: ClipRRect(
          borderRadius: BorderRadius.circular(12),
          child: SizedBox(
            width: 54,
            height: 54,
            child: r.imagePath == null
                ? const Icon(Icons.image_not_supported_outlined)
                : Image.file(
                    File(r.imagePath!),
                    cacheWidth: 144,
                    fit: BoxFit.cover,
                    errorBuilder: (_, e, s) =>
                        const Icon(Icons.broken_image_outlined),
                  ),
          ),
        ),
        title: Text(
          r.title,
          style: const TextStyle(fontWeight: FontWeight.w700),
        ),
        subtitle: Text(
          '${_date(r.createdAt)}\n${(r.score * 100).toStringAsFixed(1)} % · puntuación',
        ),
        isThreeLine: true,
        trailing: const Icon(Icons.chevron_right),
        onTap: () => _detail(r),
      ),
    ),
  );
  void _detail(Analysis r) {
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      builder: (context) => DraggableScrollableSheet(
        expand: false,
        initialChildSize: .8,
        minChildSize: .4,
        builder: (context, controller) => ListView(
          controller: controller,
          padding: const EdgeInsets.all(20),
          children: [
            if (r.imagePath != null)
              ClipRRect(
                borderRadius: BorderRadius.circular(18),
                child: Image.file(
                  File(r.imagePath!),
                  cacheWidth: 768,
                  height: 240,
                  fit: BoxFit.contain,
                  errorBuilder: (_, e, s) => const SizedBox(
                    height: 100,
                    child: Center(
                      child: Text('La fotografía ya no está disponible.'),
                    ),
                  ),
                ),
              ),
            if (r.imagePath == null) const Text('Este análisis se guardó sin fotografía.'),
            const SizedBox(height: 16),
            _resultCard(r),
            OutlinedButton.icon(
              onPressed: () {
                Navigator.pop(context);
                _delete(r);
              },
              icon: const Icon(Icons.delete_outline),
              label: const Text('Eliminar análisis'),
            ),
          ],
        ),
      ),
    );
  }

  Widget _empty(String title, String detail, IconData icon) => _panel(
    Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Icon(icon, size: 32, color: forest),
        const SizedBox(height: 14),
        Text(
          title,
          style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 17),
        ),
        const SizedBox(height: 7),
        Text(
          detail,
          style: const TextStyle(color: Color(0xFF647267), height: 1.5),
        ),
      ],
    ),
  );
  List<Widget> _guide() => [
    _heading(
      'Conoce el alcance',
      'Una herramienta de apoyo para observar hojas de tomate.',
    ),
    _panel(
      Center(
        child: Image.asset(
          'assets/images/logo.png',
          width: 164,
          height: 164,
          fit: BoxFit.contain,
          semanticLabel: 'Logo de TomatoLens',
        ),
      ),
    ),
    _panel(
      const Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'Tres categorías',
            style: TextStyle(fontSize: 19, fontWeight: FontWeight.w700),
          ),
          SizedBox(height: 12),
          Text(
            'Hoja sana\nCategoría para hojas etiquetadas como sanas en el conjunto de entrenamiento.\n\nTizón temprano\nCategoría de síntomas etiquetados como early blight.\n\nTizón tardío\nCategoría de síntomas etiquetados como late blight.',
            style: TextStyle(height: 1.6),
          ),
        ],
      ),
    ),
    _panel(
      const Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'Lee los resultados con cuidado',
            style: TextStyle(fontSize: 19, fontWeight: FontWeight.w700),
          ),
          SizedBox(height: 12),
          Text(
            'La app siempre compara tres categorías: no detecta automáticamente si la foto pertenece a otro cultivo o enfermedad. Un porcentaje alto puede acompañar una predicción incorrecta.\n\nEl entrenamiento utiliza PlantVillage. El desempeño en ese conjunto no demuestra precisión en cultivos reales. Consulta a un especialista para decisiones de manejo.',
            style: TextStyle(height: 1.6),
          ),
        ],
      ),
    ),
    _panel(
      Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            'Tus datos se quedan contigo',
            style: TextStyle(fontSize: 19, fontWeight: FontWeight.w700),
          ),
          const SizedBox(height: 12),
          const Text(
            'La clasificación se ejecuta localmente. Tú decides si cada registro conserva una copia privada de la foto. Puedes borrar cada registro o vaciar el historial. Al desinstalar, puedes perder estos datos.',
            style: TextStyle(height: 1.6),
          ),
          const SizedBox(height: 18),
          if (_preferencesReady) ...[
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('Conservar fotografías'),
              subtitle: const Text('Solo afecta los análisis que guardes desde ahora.'),
              value: _preferences.keepPhoto,
              onChanged: _changingPreferences || _saving || _busy ? null : (value) =>
                  _setPreferences(SavePreferences(keepPhoto: value, autoSave: _preferences.autoSave)),
            ),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('Guardar automáticamente'),
              subtitle: const Text('Añade los próximos resultados al historial al terminar el análisis.'),
              value: _preferences.autoSave,
              onChanged: _changingPreferences || _saving || _busy ? null : (value) =>
                  _setPreferences(SavePreferences(keepPhoto: _preferences.keepPhoto, autoSave: value)),
            ),
          ] else
            TextButton(
              onPressed: _loadPreferences,
              child: const Text('Cargar preferencias de guardado'),
            ),
          Text('Modelo: ${_version.isEmpty ? 'no disponible' : _version}'),
          if (_version == 'legacy-v1')
            const Padding(
              padding: EdgeInsets.only(top: 8),
              child: Text(
                'Modelo inicial: integración corregida. Pendiente de reentrenamiento y evaluación independiente.',
                style: TextStyle(color: Color(0xFF8B5B22), height: 1.5),
              ),
            ),
        ],
      ),
    ),
  ];
  String _date(DateTime date) {
    final d = date.toLocal();
    String two(int n) => n.toString().padLeft(2, '0');
    return '${two(d.day)}/${two(d.month)}/${d.year} · ${two(d.hour)}:${two(d.minute)}';
  }
}

enum _PreviewAction { change, analyze }

class _Tip extends StatelessWidget {
  const _Tip({required this.icon, required this.text, required this.detail});
  final IconData icon;
  final String text, detail;
  @override
  Widget build(BuildContext context) => Row(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Icon(icon, color: forest),
      const SizedBox(width: 14),
      Expanded(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(text, style: const TextStyle(fontWeight: FontWeight.w700)),
            const SizedBox(height: 4),
            Text(
              detail,
              style: const TextStyle(color: Color(0xFF647267), height: 1.4),
            ),
          ],
        ),
      ),
    ],
  );
}

/// Display the symbol in a compact square using layout clipping only.
/// The source PNG remains unchanged, including its wordmark and transparency.
class _BrandMark extends StatelessWidget {
  const _BrandMark({required this.size});
  final double size;

  @override
  Widget build(BuildContext context) {
    // Symbol bounds measured on the supplied 1254 x 1254 image.
    // Crop rectangle: x=210, y=100, width=834, height=834.
    final scale = size / 834;
    final extent = 1254 * scale;
    return Semantics(
      image: true,
      label: 'TomatoLens',
      child: SizedBox.square(
        dimension: size,
        child: ClipRect(
          child: OverflowBox(
            alignment: Alignment.topLeft,
            minWidth: extent,
            maxWidth: extent,
            minHeight: extent,
            maxHeight: extent,
            child: Transform.translate(
              offset: Offset(-210 * scale, -100 * scale),
              child: Image.asset(
                'assets/images/logo.png',
                width: extent,
                height: extent,
                fit: BoxFit.fill,
                excludeFromSemantics: true,
              ),
            ),
          ),
        ),
      ),
    );
  }
}
